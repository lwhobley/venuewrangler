-- pgTAP tests for supabase/migrations/20261013100200_review_fixes_db_part3.sql:
-- All Staff read state (4), schedule roster owners (5), push token takeover (6) and legacy
-- chat attachment reads (9).

begin;
select plan(19);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000003a1', 'p3-staff1@example.com'),
  ('00000000-0000-0000-0000-0000000003a2', 'p3-staff2@example.com'),
  ('00000000-0000-0000-0000-0000000003a3', 'p3-staff3@example.com'),
  ('00000000-0000-0000-0000-0000000003a4', 'p3-org-owner@example.com'),
  ('00000000-0000-0000-0000-0000000003b1', 'p3-org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000003a1', 'P3 Org A'),
  ('10000000-0000-0000-0000-0000000003b1', 'P3 Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000003a1', '10000000-0000-0000-0000-0000000003a1', 'P3 Venue A1'),
  ('20000000-0000-0000-0000-0000000003b1', '10000000-0000-0000-0000-0000000003b1', 'P3 Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000003a1', '10000000-0000-0000-0000-0000000003a1', '20000000-0000-0000-0000-0000000003a1', 'staff'),
  ('00000000-0000-0000-0000-0000000003a2', '10000000-0000-0000-0000-0000000003a1', '20000000-0000-0000-0000-0000000003a1', 'staff'),
  ('00000000-0000-0000-0000-0000000003a3', '10000000-0000-0000-0000-0000000003a1', '20000000-0000-0000-0000-0000000003a1', 'staff'),
  ('00000000-0000-0000-0000-0000000003a4', '10000000-0000-0000-0000-0000000003a1', null, 'organization_owner'),
  ('00000000-0000-0000-0000-0000000003b1', '10000000-0000-0000-0000-0000000003b1', null, 'organization_owner');

-- A DM between staff 1 and staff 2 (the membership rows are inserted as the owner, bypassing RLS).
insert into public.conversations (id, organization_id, venue_id, type, name) values
  ('c3000000-0000-0000-0000-0000000003c1', '10000000-0000-0000-0000-0000000003a1', '20000000-0000-0000-0000-0000000003a1', 'dm', null);
insert into public.conversation_members (conversation_id, user_id) values
  ('c3000000-0000-0000-0000-0000000003c1', '00000000-0000-0000-0000-0000000003a1'),
  ('c3000000-0000-0000-0000-0000000003c1', '00000000-0000-0000-0000-0000000003a2');

-- ---------------------------------------------------------------------------
-- 4. All Staff read state: a venue staff member can record a read; a non-member cannot.
-- The All Staff id is resolved as the owner, before switching roles. A non-member cannot see
-- the channel through RLS, so a subquery as that user would return NULL and the derive trigger
-- would fail with 23503 before the policy ran. The fixture must not depend on RLS visibility.
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('p3.all_staff_id', (
    select c.id::text from public.conversations c
    where c.venue_id = '20000000-0000-0000-0000-0000000003a1' and c.type = 'all_staff'
  ), true);
end
$$;

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a1';

select lives_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values (current_setting('p3.all_staff_id')::uuid, '00000000-0000-0000-0000-0000000003a1')
     on conflict (conversation_id, user_id) do update set read_at = now() $$,
  'R4: a staff member can record a read for the venue All Staff channel'
);

select is(
  (select count(*)::int from public.conversation_reads cr
    join public.conversations c on c.id = cr.conversation_id
   where c.type = 'all_staff' and cr.user_id = '00000000-0000-0000-0000-0000000003a1'),
  1,
  'R4: the All Staff read row is stored for the caller'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003b1';
select throws_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values (current_setting('p3.all_staff_id')::uuid, '00000000-0000-0000-0000-0000000003b1') $$,
  '42501', null,
  'R4: a user with no role in the venue cannot record a read for its All Staff channel'
);

-- ---------------------------------------------------------------------------
-- 5. The schedule roster includes the organization owner.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a1';

select is(
  (select count(*)::int from public.venue_schedule_roster('20000000-0000-0000-0000-0000000003a1')
    where user_id = '00000000-0000-0000-0000-0000000003a4'),
  1,
  'Roster5: an organization owner appears in venue_schedule_roster'
);

select is(
  (select r.role::text from public.venue_schedule_roster('20000000-0000-0000-0000-0000000003a1') r
    where r.user_id = '00000000-0000-0000-0000-0000000003a4'),
  'organization_owner',
  'Roster5: the organization owner keeps the org-level role'
);

select is(
  (select count(*)::int from public.venue_schedule_roster('20000000-0000-0000-0000-0000000003a1')
    where user_id = '00000000-0000-0000-0000-0000000003a2'),
  1,
  'Roster5: venue-level staff still appear in the schedule roster'
);

-- ---------------------------------------------------------------------------
-- 6. Push token takeover is limited to disabled or orphaned registrations.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000003a1', 'p3-token-live-0001', 'android') $$,
  'P6: staff 1 registers a live device token'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a2';
select throws_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000003a1', 'p3-token-live-0001', 'android') $$,
  '42501', null,
  'P6: another active staff member cannot take over a live token'
);

reset role;
select is(
  (select user_id from public.push_tokens where token = 'p3-token-live-0001'),
  '00000000-0000-0000-0000-0000000003a1'::uuid,
  'P6: the live token still belongs to its active registrant'
);

-- A disabled registration may be re-registered by another member.
update public.push_tokens set enabled = false, disabled_at = now()
  where token = 'p3-token-live-0001';

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a2';
select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000003a1', 'p3-token-live-0001', 'android') $$,
  'P6: a disabled token can be re-registered by another member'
);
reset role;
select is(
  (select user_id from public.push_tokens where token = 'p3-token-live-0001'),
  '00000000-0000-0000-0000-0000000003a2'::uuid,
  'P6: the re-registered token belongs to the new registrant'
);

-- A registration whose owner has left the organization may move to a venue member.
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a2';
select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000003a1', 'p3-token-left-0002', 'ios') $$,
  'P6: staff 2 registers a token'
);
reset role;
delete from public.memberships
  where user_id = '00000000-0000-0000-0000-0000000003a2'
    and venue_id = '20000000-0000-0000-0000-0000000003a1';

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a1';
select lives_ok(
  $$ select public.register_push_token('20000000-0000-0000-0000-0000000003a1', 'p3-token-left-0002', 'ios') $$,
  'P6: a token whose owner has left the organization can move to a venue member'
);
reset role;
select is(
  (select user_id from public.push_tokens where token = 'p3-token-left-0002'),
  '00000000-0000-0000-0000-0000000003a1'::uuid,
  'P6: the orphaned token now belongs to the venue member who registered it'
);

-- ---------------------------------------------------------------------------
-- 9. Legacy 3-segment chat objects are readable only by conversation members.
-- ---------------------------------------------------------------------------
insert into storage.objects (bucket_id, name) values
  ('chat', '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1'),
  ('chat', '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/legacy-file.pdf'),
  ('chat', '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1/current.pdf');

-- Staff 3 is venue staff but not in the DM.
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a3';

select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'chat'
      and name = '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1'),
  0,
  'L9: a venue staff member outside the DM cannot read a legacy object for it'
);

select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'chat'
      and name = '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/legacy-file.pdf'),
  0,
  'L9: a legacy object without a conversation id is not readable through the venue role'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a1';
select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'chat'
      and name = '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1'),
  1,
  'L9: a DM member can still read the legacy object for the DM'
);

select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'chat'
      and name = '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1/current.pdf'),
  1,
  'L9: a DM member can still read a current 4-segment attachment'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000003a3';
select is(
  (select count(*)::int from storage.objects
    where bucket_id = 'chat'
      and name = '10000000-0000-0000-0000-0000000003a1/20000000-0000-0000-0000-0000000003a1/c3000000-0000-0000-0000-0000000003c1/current.pdf'),
  0,
  'L9: a venue staff member outside the DM cannot read a current attachment for it'
);

select * from finish();
rollback;
