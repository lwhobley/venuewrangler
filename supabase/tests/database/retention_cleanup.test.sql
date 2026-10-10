-- pgTAP tests for app_hidden.run_retention_cleanup (20261010120000).

begin;
select plan(8);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'retention@example.com');

insert into public.audit_log (id, action, created_at) values
  ('a1000000-0000-0000-0000-000000000001', 'old', now() - interval '366 days'),
  ('a1000000-0000-0000-0000-000000000002', 'recent', now() - interval '364 days');

insert into public.attestation_challenges
  (id, user_id, device_id, nonce_hash, issued_at, expires_at) values
  ('a2000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'd',
   'hash-old', now() - interval '2 hours', now() - interval '2 hours' + interval '5 minutes'),
  ('a2000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'd',
   'hash-live', now(), now() + interval '5 minutes');

insert into public.retained_time_entries
  (id, original_time_entry_id, anonymized_user_label, clock_in_at, clock_out_at) values
  ('a3000000-0000-0000-0000-000000000001', gen_random_uuid(), 'deleted_user_1',
   now() - interval '3 years 2 days', now() - interval '3 years 1 day'),
  ('a3000000-0000-0000-0000-000000000002', gen_random_uuid(), 'deleted_user_1',
   now() - interval '2 years', now() - interval '2 years' + interval '8 hours');

select results_eq(
  $$ select audit_log_deleted, attestation_challenges_deleted, retained_time_entries_deleted
     from app_hidden.run_retention_cleanup() $$,
  $$ values (1::bigint, 1::bigint, 1::bigint) $$,
  'cleanup reports one expired row removed from each table'
);

select is((select count(*)::int from public.audit_log where id = 'a1000000-0000-0000-0000-000000000001'), 0,
  'audit log older than 365 days is deleted');
select is((select count(*)::int from public.audit_log where id = 'a1000000-0000-0000-0000-000000000002'), 1,
  'audit log within 365 days is kept');
select is((select count(*)::int from public.attestation_challenges where nonce_hash = 'hash-old'), 0,
  'long-expired attestation challenge is deleted');
select is((select count(*)::int from public.attestation_challenges where nonce_hash = 'hash-live'), 1,
  'unexpired attestation challenge is kept');
select is((select count(*)::int from public.retained_time_entries where id = 'a3000000-0000-0000-0000-000000000001'), 0,
  'wage record older than three years is deleted');
select is((select count(*)::int from public.retained_time_entries where id = 'a3000000-0000-0000-0000-000000000002'), 1,
  'wage record within three years is kept');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ select app_hidden.run_retention_cleanup() $$,
  '42501', null,
  'signed-in users cannot run retention cleanup'
);

select * from finish();
rollback;
