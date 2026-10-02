-- pgTAP authorization tests for payroll_connections (supabase/migrations/20261002140000).
-- Same org/venue/membership fixture shape as operational_tasks_rls.test.sql. Also exercises
-- the column-level grant that keeps encrypted token columns out of client reach even when
-- the row-level policy matches.

begin;
select plan(9);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Seeded as table owner (bypasses RLS and column grants), the same way an oauth Edge
-- Function's service-role client would write this row in production.
insert into public.payroll_connections
  (venue_id, provider, status, external_account_id, encrypted_access_token, encrypted_refresh_token)
values
  ('20000000-0000-0000-0000-0000000000a1', 'square', 'connected', 'merchant_123', 'enc_access_xyz', 'enc_refresh_xyz');

-- ---------------------------------------------------------------------------
-- select: row-level (manager tier only)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select is(
  (select status from public.payroll_connections where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  'connected',
  'venue_manager can see their venue''s payroll connection status'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';

select is(
  (select count(*)::int from public.payroll_connections where venue_id = '20000000-0000-0000-0000-0000000000a1'),
  0,
  'a non-manager staff member cannot see the venue''s payroll connection'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.payroll_connections),
  0,
  'org_b_owner cannot see org_a''s payroll connection (cross-tenant)'
);

-- ---------------------------------------------------------------------------
-- select: column-level (encrypted tokens are never selectable by a client)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';

select throws_ok(
  $$ select encrypted_access_token from public.payroll_connections where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  '42501',
  null,
  'even a venue_manager cannot select the encrypted access token column'
);

select throws_ok(
  $$ select encrypted_refresh_token from public.payroll_connections where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  '42501',
  null,
  'even a venue_manager cannot select the encrypted refresh token column'
);

select lives_ok(
  $$ select id, provider, status, external_account_id, token_expires_at from public.payroll_connections where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'a venue_manager can select the non-secret columns'
);

-- ---------------------------------------------------------------------------
-- write: service-role (Edge Function) only
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ insert into public.payroll_connections (venue_id, provider) values ('20000000-0000-0000-0000-0000000000a1', 'gusto') $$,
  '42501',
  null,
  'a client can never create a payroll connection (service-role/oauth Edge Function only)'
);

select throws_ok(
  $$ update public.payroll_connections set status = 'disconnected' where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  '42501',
  null,
  'a client can never modify a payroll connection directly'
);

reset role;

select is(
  (select count(*)::int from public.payroll_connections),
  1,
  'sanity: exactly one connection row exists after all the above (service-role view)'
);

select * from finish();
rollback;
