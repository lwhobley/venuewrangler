-- pgTAP authorization tests for attestation_challenges (supabase/migrations/20261003004000).
-- This table has no client-facing policy at all (same pattern as platform_admins): only the
-- service-role client used by the device-attestation Edge Function should ever read or write
-- it, since its entire purpose is server-side single-use tracking a client must not be able to
-- tamper with or snoop on (that would defeat the replay protection it exists to provide).

begin;
select plan(4);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000007', 'attest-owner@example.com');

-- Seeded as table owner (bypasses RLS), the way the device-attestation Edge Function's
-- service-role client would write this row in production.
insert into public.attestation_challenges (user_id, device_id, nonce_hash, expires_at) values
  ('00000000-0000-0000-0000-000000000007', 'device-abc', 'deadbeef', now() + interval '5 minutes');

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000007';

select throws_ok(
  $$ select count(*) from public.attestation_challenges $$,
  '42501',
  null,
  'a client can never read attestation challenges, even their own (no select policy and no SELECT grant)'
);

select throws_ok(
  $$ insert into public.attestation_challenges (user_id, device_id, nonce_hash, expires_at) values ('00000000-0000-0000-0000-000000000007', 'device-xyz', 'cafef00d', now() + interval '5 minutes') $$,
  '42501',
  null,
  'a client can never forge its own attestation challenge row'
);

select throws_ok(
  $$ update public.attestation_challenges set consumed_at = now() where nonce_hash = 'deadbeef' $$,
  '42501',
  null,
  'a client cannot self-consume or un-consume a challenge (no update policy and no UPDATE grant)'
);

reset role;

select is(
  (select consumed_at from public.attestation_challenges where nonce_hash = 'deadbeef'),
  null,
  'the denied client update above did not actually mark the challenge consumed'
);

select * from finish();
rollback;
