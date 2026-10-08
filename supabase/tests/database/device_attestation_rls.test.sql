-- pgTAP authorization tests for device_attestations (supabase/migrations/20261002170000).

begin;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

-- Seeded as table owner (bypasses RLS), the way the device-attestation Edge Function's
-- service-role client would write this row in production.
insert into public.device_attestations (user_id, platform, device_id, status, detail) values
  ('00000000-0000-0000-0000-000000000005', 'android', 'device-abc', 'valid', '{"appRecognitionVerdict": "PLAY_RECOGNIZED"}'::jsonb);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.device_attestations),
  1,
  'a user can see their own device attestation history'
);

select is(
  (select status from public.device_attestations where user_id = '00000000-0000-0000-0000-000000000005'),
  'valid',
  'the recorded status is visible to the owning user'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.device_attestations),
  0,
  'a different user cannot see someone else''s device attestation history'
);

select throws_ok(
  $$ insert into public.device_attestations (user_id, platform, device_id, status) values ('00000000-0000-0000-0000-000000000006', 'ios', 'device-xyz', 'observed') $$,
  '42501',
  null,
  'a client can never create its own attestation record (service-role/Edge Function only)'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select lives_ok(
  $$ update public.device_attestations set status = 'invalid' where user_id = '00000000-0000-0000-0000-000000000005' $$,
  'a client''s update attempt executes without error but matches no rows (no update policy exists)'
);
select is(
  (select status from public.device_attestations where user_id = '00000000-0000-0000-0000-000000000005'),
  'valid',
  'client update attempt cannot alter the attestation status'
);

select * from finish();
rollback;
