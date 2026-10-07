-- pgTAP tests for public.request_account_deletion (supabase/migrations/*_account_deletion).
-- Personal "delete my account" only (see that migration's header comment for why tenant/org
-- offboarding is out of scope) — covers the sole-owner guard, wage-record retention,
-- attribution anonymization, and that the async auth.users-deletion job gets queued.

begin;
select plan(12);

insert into auth.users (id, email) values
  ('40000000-0000-0000-0000-000000000001', 'sole-owner@example.com'),
  ('40000000-0000-0000-0000-000000000003', 'departing-staff@example.com');

insert into public.organizations (id, name, created_by) values
  ('50000000-0000-0000-0000-00000000000a', 'Org A', '40000000-0000-0000-0000-000000000001');

insert into public.venues (id, organization_id, name) values
  ('60000000-0000-0000-0000-0000000000a1', '50000000-0000-0000-0000-00000000000a', 'Venue A1');

-- User 001 is Org A's ONLY organization_owner (no co-owner anywhere) — the sole-owner guard
-- must block them. User 003 is plain staff, never an owner of anything.
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('40000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('40000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000a1', 'staff');

-- A time entry and an audit_log row the departing staff member is attributed on, to verify
-- retention/anonymization. app_hidden.prepare_time_entry_insert always overrides user_id to
-- auth.uid() unless the caller has a manager-level role on the venue (never true here), so
-- the claim must name the intended owner before this raw insert.
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000003';
insert into public.time_entries (
  id, organization_id, venue_id, user_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m
) values (
  '70000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000a1',
  '40000000-0000-0000-0000-000000000003', 0, 0, 5.0
);

insert into public.audit_log (organization_id, venue_id, actor_user_id, action, target_table, target_id)
values (
  '50000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-0000000000a1',
  '40000000-0000-0000-0000-000000000003', 'time_entry.correct', 'time_entries',
  '70000000-0000-0000-0000-000000000001'
);

-- ---------------------------------------------------------------------------
-- The sole owner of Org A cannot delete their account.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000001';

select throws_ok(
  $$select public.request_account_deletion('testing')$$,
  '42501', null,
  'the sole organization_owner of Org A is blocked from deleting their account'
);

select is(
  (select count(*)::int from public.memberships where user_id = '40000000-0000-0000-0000-000000000001'::uuid),
  1,
  'the blocked sole owner''s membership is untouched'
);

-- ---------------------------------------------------------------------------
-- An unauthenticated caller cannot request deletion for anyone.
-- ---------------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok(
  $$select public.request_account_deletion()$$,
  '42501', null,
  'an unauthenticated caller cannot request account deletion'
);
reset role;

-- ---------------------------------------------------------------------------
-- The departing staff member (not an owner of anything) can delete their account.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000003';

select lives_ok(
  $$select public.request_account_deletion('no longer working here')$$,
  'a non-owner can delete their own account'
);

reset role;

select is(
  (select count(*)::int from public.profiles where id = '40000000-0000-0000-0000-000000000003'::uuid),
  0,
  'the departing user''s profile row is gone'
);

select is(
  (select count(*)::int from public.memberships where user_id = '40000000-0000-0000-0000-000000000003'::uuid),
  0,
  'the departing user''s membership is gone'
);

select is(
  (select count(*)::int from public.time_entries where user_id = '40000000-0000-0000-0000-000000000003'::uuid),
  0,
  'the departing user''s time_entries row no longer exists'
);

select is(
  (select count(*)::int from public.retained_time_entries
    where original_time_entry_id = '70000000-0000-0000-0000-000000000001'::uuid
      and anonymized_user_label = 'deleted_user_40000000-0000-0000-0000-000000000003'),
  1,
  'the time entry was preserved in retained_time_entries under an anonymized label'
);

select is(
  (select actor_user_id from public.audit_log
    where target_id = '70000000-0000-0000-0000-000000000001'::uuid and action = 'time_entry.correct'),
  null::uuid,
  'the pre-existing audit_log row''s actor attribution was cleared, not the row itself'
);

select is(
  (select count(*)::int from public.audit_log
    where action = 'account.delete_requested' and target_id = '40000000-0000-0000-0000-000000000003'::uuid),
  1,
  'the deletion itself is recorded in audit_log'
);

select is(
  (select count(*)::int from public.account_deletion_jobs
    where user_id = '40000000-0000-0000-0000-000000000003'::uuid and status in ('pending', 'processing', 'failed')),
  1,
  'an account_deletion_jobs row was queued for the Auth Admin API deletion step'
);

-- ---------------------------------------------------------------------------
-- Org A's owner membership is unaffected by someone else's deletion.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from public.memberships where organization_id = '50000000-0000-0000-0000-00000000000a'::uuid),
  1,
  'the sole owner''s own membership (still blocked from deleting) is untouched'
);

select * from finish();
rollback;
