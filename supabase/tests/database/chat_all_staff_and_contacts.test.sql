-- pgTAP tests for 20261012120000_chat_all_staff_and_contacts.sql.
-- Fixtures: Org A, Venue A1 (manager 004, staff 005), Venue A2 (staff 007), org owner 009;
-- Org B, Venue B1 (staff 006).

begin;
select plan(12);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'b1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000007', 'a2-staff@example.com'),
  ('00000000-0000-0000-0000-000000000009', 'a-owner@example.com');

insert into public.profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000000004', 'Mia Manager'),
  ('00000000-0000-0000-0000-000000000005', 'Sam Staff'),
  ('00000000-0000-0000-0000-000000000009', 'Olive Owner')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000a2', '10000000-0000-0000-0000-00000000000a', 'Venue A2'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a2', 'staff'),
  ('00000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-00000000000b', 'staff');

-- ---------------------------------------------------------------------------
-- 1-3. Every venue gets exactly one All Staff channel when it is created
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.conversations
   where venue_id = '20000000-0000-0000-0000-0000000000a1' and type = 'all_staff'),
  1::bigint,
  'a new venue gets an All Staff channel'
);

select is(
  (select name from public.conversations
   where venue_id = '20000000-0000-0000-0000-0000000000a2' and type = 'all_staff'),
  'All Staff',
  'the channel is named All Staff'
);

select throws_ok(
  $$ insert into public.conversations (venue_id, organization_id, type, name)
     values ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'all_staff', 'Second') $$,
  '23505',
  null,
  'a venue cannot have a second All Staff channel'
);

-- ---------------------------------------------------------------------------
-- 4. Venue staff can read their venue's All Staff channel
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- A1 staff

select is(
  (select count(*) from public.conversations
   where venue_id = '20000000-0000-0000-0000-0000000000a1' and type = 'all_staff'),
  1::bigint,
  'venue staff see the All Staff channel'
);

-- ---------------------------------------------------------------------------
-- 5-7. chat_contacts: venue members and org owners, minus the caller
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select user_id from public.chat_contacts('20000000-0000-0000-0000-0000000000a1') order by user_id $$,
  $$ values ('00000000-0000-0000-0000-000000000004'::uuid),
            ('00000000-0000-0000-0000-000000000009'::uuid) $$,
  'staff see the venue manager and the org owner, not themselves or other venues'' staff'
);

select results_eq(
  $$ select display_name from public.chat_contacts('20000000-0000-0000-0000-0000000000a1')
     where user_id = '00000000-0000-0000-0000-000000000004' $$,
  $$ values ('Mia Manager'::text) $$,
  'contacts carry display names'
);

select throws_ok(
  $$ select * from public.chat_contacts('20000000-0000-0000-0000-00000000000b') $$,
  '42501',
  null,
  'a non-member cannot list another venue''s contacts'
);

-- ---------------------------------------------------------------------------
-- 8-12. create_or_get_dm: only with someone in the venue
-- ---------------------------------------------------------------------------
select isnt(
  public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000004'),
  null,
  'staff can start a DM with their venue manager'
);

select is(
  public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000004'),
  (select c.id from public.conversations c
   where c.venue_id = '20000000-0000-0000-0000-0000000000a1' and c.type = 'dm'),
  'starting the same DM again returns the existing conversation'
);

select isnt(
  public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000009'),
  null,
  'staff can start a DM with the org owner'
);

select throws_ok(
  $$ select public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000007') $$,
  '22023',
  'that person is not part of this venue',
  'a DM cannot be started with staff of another venue'
);

select throws_ok(
  $$ select public.create_or_get_dm('20000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000006') $$,
  '22023',
  'that person is not part of this venue',
  'a DM cannot be started with someone from another organization'
);

select * from finish();
rollback;
