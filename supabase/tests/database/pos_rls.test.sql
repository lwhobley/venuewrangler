-- pgTAP authorization and functionality tests for bidirectional POS module (20261002270000).
-- Fixtures: Org A, Venue A1 (manager 004, staff 005), Org B, Venue B1 (owner 006).

begin;
select plan(13);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1. Trigger test: pos_connections derives organization_id
-- ---------------------------------------------------------------------------
insert into public.pos_connections (
  id, venue_id, organization_id, provider, webhook_secret_hash, credentials_encrypted
) values (
  '80000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b', -- wrong org
  'toast',
  'hashed-secret-value-123',
  'encrypted-credentials-blob-xyz'
);

select results_eq(
  $$ select organization_id from public.pos_connections where id = '80000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'pos_connections derives organization_id from venue_id on insert'
);

-- ---------------------------------------------------------------------------
-- 2. Trigger test: pos_checks derives organization_id
-- ---------------------------------------------------------------------------
insert into public.pos_checks (
  id, venue_id, organization_id, pos_connection_id, provider, external_check_id,
  opened_at, subtotal_cents, total_cents
) values (
  '90000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b',
  '80000000-0000-0000-0000-000000000001',
  'toast',
  'chk-toast-001',
  now(),
  5000,
  5500
);

select results_eq(
  $$ select organization_id from public.pos_checks where id = '90000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'pos_checks derives organization_id from venue_id on insert'
);

-- ---------------------------------------------------------------------------
-- 3. Trigger test: pos_outbound_commands derives venue_id and org from connection
-- ---------------------------------------------------------------------------
insert into public.pos_outbound_commands (
  id, pos_connection_id, venue_id, organization_id, command_type, payload
) values (
  'a0000000-0000-0000-0000-000000000001',
  '80000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-00000000000b',
  '10000000-0000-0000-0000-00000000000b',
  'update_item_availability_86',
  '{"itemGuid": "toast-item-salmon", "isAvailable": false}'::jsonb
);

select results_eq(
  $$ select venue_id, organization_id from public.pos_outbound_commands where id = 'a0000000-0000-0000-0000-000000000001' $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1'::uuid, '10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'pos_outbound_commands derives venue_id and organization_id from connection'
);

-- ---------------------------------------------------------------------------
-- 4 & 5. Column Security: Authenticated cannot select secrets
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager

select throws_ok(
  $$ select webhook_secret_hash from public.pos_connections $$,
  '42501',
  null,
  'authenticated user cannot select webhook_secret_hash from pos_connections'
);

select throws_ok(
  $$ select credentials_encrypted from public.pos_connections $$,
  '42501',
  null,
  'authenticated user cannot select credentials_encrypted from pos_connections'
);

-- ---------------------------------------------------------------------------
-- 6 & 7. Manager can view connection status; Staff cannot
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select provider, status from public.pos_connections where id = '80000000-0000-0000-0000-000000000001' $$,
  $$ values ('toast'::text, 'active'::text) $$,
  'manager can view non-secret pos_connections fields'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select is_empty(
  $$ select id from public.pos_connections where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'staff cannot view pos_connections (manager-only RLS)'
);

-- ---------------------------------------------------------------------------
-- 8 & 9. Staff can view checks in venue; Org B cannot (tenant isolation)
-- ---------------------------------------------------------------------------
select results_ne(
  $$ select count(*)::int from public.pos_checks where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  $$ values (0) $$,
  'staff can view pos_checks in venue A1'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006'; -- Org B

select is_empty(
  $$ select id from public.pos_checks where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot view pos_checks from venue A1 (tenant isolation)'
);

-- ---------------------------------------------------------------------------
-- 10. Ingestion idempotency: duplicate (venue_id, provider, external_check_id)
-- ---------------------------------------------------------------------------
reset role;
select throws_ok(
  $$ insert into public.pos_checks (
       venue_id, organization_id, provider, external_check_id, opened_at, subtotal_cents, total_cents
     ) values (
       '20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a',
       'toast', 'chk-toast-001', now(), 5000, 5500
     ) $$,
  '23505',
  null,
  'duplicate check ingestion violates unique constraint (idempotency key)'
);

-- ---------------------------------------------------------------------------
-- 11 & 12. Manager can enqueue outbound command; Staff cannot
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager

select lives_ok(
  $$ insert into public.pos_outbound_commands (
       pos_connection_id, command_type, payload
     ) values (
       '80000000-0000-0000-0000-000000000001',
       'update_item_availability_86',
       '{"itemGuid": "item-beer-ipa", "isAvailable": false}'::jsonb
     ) $$,
  'manager can enqueue outbound 86 command'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff

select throws_ok(
  $$ insert into public.pos_outbound_commands (
       pos_connection_id, command_type, payload
     ) values (
       '80000000-0000-0000-0000-000000000001',
       'update_item_availability_86',
       '{"itemGuid": "item-wine", "isAvailable": false}'::jsonb
     ) $$,
  '42501',
  null,
  'staff cannot enqueue outbound command (manager-only RLS)'
);

-- ---------------------------------------------------------------------------
-- 13. Worker batch claim function: claims and updates command
-- ---------------------------------------------------------------------------
reset role;
select results_eq(
  $$ select count(*)::int from app_hidden.claim_pos_outbound_commands_batch(10) $$,
  $$ values (2) $$,
  'worker claims 2 pending outbound commands'
);

select * from finish();
rollback;
