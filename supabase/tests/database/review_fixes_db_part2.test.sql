-- pgTAP tests for supabase/migrations/20261013100100_review_fixes_db_part2.sql:
-- storage deletion dead-lettering (2), stale processing jobs (3), audit retention (7),
-- deleted-account workspace guard (8) and immutable message attachments (10).

begin;
select plan(11);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000002c1', 'p2-pending-deletion@example.com'),
  ('00000000-0000-0000-0000-0000000002c2', 'p2-clean@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000002a1', 'P2 Org');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000002a1', '10000000-0000-0000-0000-0000000002a1', 'P2 Venue');

-- ---------------------------------------------------------------------------
-- 2. An unsafe legacy row does not stall the queue.
-- The unsafe row is inserted with the path trigger disabled, the way a pre-guard legacy row
-- would exist. Its traversal segment must be dead-lettered while the valid job is claimed.
-- ---------------------------------------------------------------------------
insert into public.storage_deletion_jobs (id, organization_id, venue_id, bucket_id, object_path)
values (
  '90000000-0000-0000-0000-0000000002a1',
  '10000000-0000-0000-0000-0000000002a1',
  '20000000-0000-0000-0000-0000000002a1',
  'incident-evidence',
  '10000000-0000-0000-0000-0000000002a1/20000000-0000-0000-0000-0000000002a1/valid.png'
);

alter table public.storage_deletion_jobs disable trigger prepare_storage_deletion_job_insert;
insert into public.storage_deletion_jobs (id, organization_id, venue_id, bucket_id, object_path)
values (
  '90000000-0000-0000-0000-0000000002a2',
  '10000000-0000-0000-0000-0000000002a1',
  '20000000-0000-0000-0000-0000000002a1',
  'incident-evidence',
  '10000000-0000-0000-0000-0000000002a1/../escape.png'
);
alter table public.storage_deletion_jobs enable trigger prepare_storage_deletion_job_insert;

-- Stale 'processing' job at the attempt cap: its worker died and the lease has expired.
insert into public.storage_deletion_jobs (id, organization_id, venue_id, bucket_id, object_path)
values (
  '90000000-0000-0000-0000-0000000002a3',
  '10000000-0000-0000-0000-0000000002a1',
  '20000000-0000-0000-0000-0000000002a1',
  'incident-evidence',
  '10000000-0000-0000-0000-0000000002a1/20000000-0000-0000-0000-0000000002a1/stale.png'
);
update public.storage_deletion_jobs
  set status = 'processing', attempts = 10, updated_at = now() - interval '30 minutes'
  where id = '90000000-0000-0000-0000-0000000002a3';

select is(
  (select count(*)::int from public.claim_storage_deletion_jobs(25)
    where id = '90000000-0000-0000-0000-0000000002a1'),
  1,
  'S2: a valid job is still claimed while an unsafe legacy row is in the queue'
);

select is(
  (select status from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-0000000002a2'),
  'dead',
  'S2: the unsafe legacy row ends dead instead of stalling the claim'
);

-- ---------------------------------------------------------------------------
-- 3. Stale processing jobs at the attempt cap are dead-lettered by the claim.
-- ---------------------------------------------------------------------------
select is(
  (select status from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-0000000002a3'),
  'dead',
  'S3: a stale processing job at attempts = 10 is dead-lettered'
);

select is(
  (select last_error from public.storage_deletion_jobs where id = '90000000-0000-0000-0000-0000000002a3'),
  'stale after max attempts',
  'S3: the dead-lettered stale job records why'
);

-- ---------------------------------------------------------------------------
-- 7. Audit retention: time_entry.correct is kept three years, other rows 365 days.
-- ---------------------------------------------------------------------------
insert into public.audit_log (id, organization_id, venue_id, action, created_at) values
  ('a7000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-0000000002a1', '20000000-0000-0000-0000-0000000002a1', 'time_entry.correct', now() - interval '400 days'),
  ('a7000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-0000000002a1', '20000000-0000-0000-0000-0000000002a1', 'time_entry.correct', now() - interval '3 years 2 days'),
  ('a7000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-0000000002a1', '20000000-0000-0000-0000-0000000002a1', 'shift.updated', now() - interval '400 days');

select lives_ok(
  $$ select app_hidden.run_retention_cleanup() $$,
  'A7: retention cleanup runs'
);

select is(
  (select count(*)::int from public.audit_log where id = 'a7000000-0000-0000-0000-000000000001'),
  1,
  'A7: a time_entry.correct row 400 days old is kept (three-year window)'
);

select is(
  (select count(*)::int from public.audit_log where id = 'a7000000-0000-0000-0000-000000000002'),
  0,
  'A7: a time_entry.correct row older than three years is deleted'
);

select is(
  (select count(*)::int from public.audit_log where id = 'a7000000-0000-0000-0000-000000000003'),
  0,
  'A7: other audit rows older than 365 days are still deleted'
);

-- ---------------------------------------------------------------------------
-- 8. A user with a pending account deletion cannot create a workspace.
-- ---------------------------------------------------------------------------
insert into public.account_deletion_jobs (user_id, status)
values ('00000000-0000-0000-0000-0000000002c1', 'pending');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000002c1';

select throws_ok(
  $$ select * from public.create_workspace('Deleting Org', 'Deleting Venue', 'UTC') $$,
  '42501', null,
  'D8: a user with a pending account deletion cannot create a workspace'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000002c2';

select lives_ok(
  $$ select * from public.create_workspace('Clean Org', 'Clean Venue', 'UTC') $$,
  'D8: a user without an account deletion can still create a workspace'
);

-- ---------------------------------------------------------------------------
-- 10. Message attachments cannot be repointed after insert.
-- The app never updates messages, so authenticated has no table-level UPDATE privilege.
-- Note: the CI grant stub does not reproduce Supabase's default UPDATE grant, so this is a
-- regression guard in CI; the grant it guards against exists on real projects.
-- ---------------------------------------------------------------------------
reset role;
select ok(
  not has_table_privilege('authenticated', 'public.messages', 'UPDATE'),
  'M10: authenticated has no UPDATE privilege on messages (attachment_path is immutable)'
);

select * from finish();
rollback;
