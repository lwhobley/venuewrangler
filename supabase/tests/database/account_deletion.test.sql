-- pgTAP tests for public.request_account_deletion (supabase/migrations/*_account_deletion).
-- Personal "delete my account" only (see that migration's header comment for why tenant/org
-- offboarding is out of scope) — covers the sole-owner guard, wage-record retention,
-- attribution anonymization, and that the async auth.users-deletion job gets queued.

begin;
select plan(28);

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

-- ---------------------------------------------------------------------------
-- Ordinary operational history (20261007190000_account_deletion_fixes.sql).
-- A venue manager who has accumulated rows in exactly the tables whose client-facing guard
-- triggers used to veto the cleanup (tasks, incidents, invites, inventory, shift swaps, staff
-- request reviews) plus a POS audit event. The first version's fixture had none of these, so
-- it passed while the real flow failed with 42501 for almost any real user.
-- ---------------------------------------------------------------------------
reset role;
insert into auth.users (id, email) values
  ('40000000-0000-0000-0000-000000000004', 'busy-manager@example.com'),
  ('40000000-0000-0000-0000-000000000005', 'requester@example.com');

insert into public.organizations (id, name) values
  ('50000000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name) values
  ('60000000-0000-0000-0000-0000000000b1', '50000000-0000-0000-0000-00000000000b', 'Venue B1');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('40000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-00000000000b', '60000000-0000-0000-0000-0000000000b1', 'venue_manager'),
  ('40000000-0000-0000-0000-000000000005', '50000000-0000-0000-0000-00000000000b', '60000000-0000-0000-0000-0000000000b1', 'staff');

-- Insert/update triggers stamp auth.uid() as the actor, so each fixture runs under the JWT
-- claim of whoever would really have made it.
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000005';
insert into public.staff_requests (id, venue_id, user_id, kind, title) values
  ('90000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-0000000000b1',
   '40000000-0000-0000-0000-000000000005', 'time_off', 'Weekend off');

set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000004';
update public.staff_requests set status = 'approved'
  where id = '90000000-0000-0000-0000-000000000001';
insert into public.shifts (id, venue_id, start_time, end_time, staff_id) values
  ('91000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-0000000000b1',
   now() + interval '1 day', now() + interval '1 day 4 hours', '40000000-0000-0000-0000-000000000004');
insert into public.operational_tasks (venue_id, title, assigned_to) values
  ('60000000-0000-0000-0000-0000000000b1', 'Close bar', '40000000-0000-0000-0000-000000000004');
insert into public.incidents (venue_id, title) values
  ('60000000-0000-0000-0000-0000000000b1', 'Broken glass');
insert into public.invites (venue_id, email, role) values
  ('60000000-0000-0000-0000-0000000000b1', 'new-hire@example.com', 'staff');
insert into public.inventory_items (venue_id, name) values
  ('60000000-0000-0000-0000-0000000000b1', 'Well vodka');
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000005';
insert into public.shift_swaps (shift_id, requested_by, offered_to) values
  ('91000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000005',
   '40000000-0000-0000-0000-000000000004');
insert into public.pos_connections (id, organization_id, venue_id, provider) values
  ('92000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-00000000000b',
   '60000000-0000-0000-0000-0000000000b1', 'toast');
insert into public.pos_audit_events (connection_id, event_type, actor_id) values
  ('92000000-0000-0000-0000-000000000001', 'test', '40000000-0000-0000-0000-000000000004');

set local role authenticated;
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000004';

select lives_ok(
  $$select public.request_account_deletion('busy manager')$$,
  'a manager with tasks, incidents, invites, inventory edits, swaps and request reviews can delete their account'
);

reset role;

select is(
  app_hidden.account_deletion_in_progress(),
  false,
  'the guard-bypass flag does not outlive the request that set it'
);

select is(
  (select count(*)::int from public.operational_tasks
    where title = 'Close bar' and assigned_to is null),
  1,
  'the task survives with its assignee forgotten'
);

select is(
  (select count(*)::int from public.incidents
    where title = 'Broken glass' and reported_by is null),
  1,
  'the incident survives with its reporter forgotten'
);

select is(
  (select count(*)::int from public.invites
    where email = 'new-hire@example.com' and invited_by is null),
  1,
  'the invite survives with its inviter forgotten'
);

select is(
  (select count(*)::int from public.inventory_items
    where name = 'Well vodka' and updated_by is null),
  1,
  'the inventory edit survives and is not re-stamped with the departing user'
);

select is(
  (select count(*)::int from public.staff_requests
    where id = '90000000-0000-0000-0000-000000000001' and reviewer_id is null and status = 'approved'),
  1,
  'a request the departing manager reviewed keeps its outcome, reviewer forgotten'
);

select is(
  (select count(*)::int from public.pos_audit_events
    where event_type = 'test' and actor_id is null),
  1,
  'the POS audit event survives with its actor forgotten'
);

select is(
  (select count(*)::int from public.shift_swaps
    where requested_by = '40000000-0000-0000-0000-000000000005'::uuid and offered_to is null),
  1,
  'a swap offered to the departing user is kept, with the offer cleared'
);

-- A retry after a dropped response must not queue a second job.
set local role authenticated;
set local "request.jwt.claim.sub" to '40000000-0000-0000-0000-000000000004';
select lives_ok(
  $$select public.request_account_deletion('retry')$$,
  'requesting deletion a second time is harmless'
);
reset role;

select is(
  (select count(*)::int from public.account_deletion_jobs
    where user_id = '40000000-0000-0000-0000-000000000004'::uuid),
  1,
  'a retry reuses the live job instead of queueing another'
);

-- A job stranded 'processing' by a worker that died is reclaimed; one that has spent all its
-- attempts is dead-lettered instead of retried forever.
update public.account_deletion_jobs
  set status = 'processing', attempts = 3, updated_at = now() - interval '20 minutes'
  where user_id = '40000000-0000-0000-0000-000000000004';
select is(
  app_hidden.sweep_account_deletion_jobs(),
  1,
  'the sweep reclaims a job stranded in processing'
);

update public.account_deletion_jobs
  set status = 'processing', attempts = 10, updated_at = now() - interval '20 minutes'
  where user_id = '40000000-0000-0000-0000-000000000004';
select is(
  app_hidden.sweep_account_deletion_jobs(),
  0,
  'the sweep does not redispatch a job that has spent its attempts'
);

select is(
  (select status from public.account_deletion_jobs where user_id = '40000000-0000-0000-0000-000000000004'),
  'dead',
  'and dead-letters it'
);

-- The real final step, as the Auth Admin API performs it: nothing may still reference the
-- departed account, and none of the SET NULL / CASCADE actions may be vetoed by a guard.
select lives_ok(
  $$delete from auth.users where id = '40000000-0000-0000-0000-000000000004'$$,
  'the final auth.users delete is not blocked by anything referencing the departed account'
);

select * from finish();
rollback;
