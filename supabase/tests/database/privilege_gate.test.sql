-- H8: session GUCs must not authorize integrity bypasses; only the private
-- app_hidden.privilege_gate (written inside SECURITY DEFINER RPCs) may.

begin;
select plan(8);

insert into auth.users (id, email) values
  ('e1000000-0000-0000-0000-000000000001', 'gate-manager@example.com'),
  ('e1000000-0000-0000-0000-000000000002', 'gate-staff@example.com');

insert into public.organizations (id, name) values
  ('e2000000-0000-0000-0000-00000000000a', 'Gate Org');

insert into public.venues (id, organization_id, name, latitude, longitude, geofence_radius_m) values
  ('e3000000-0000-0000-0000-0000000000a1', 'e2000000-0000-0000-0000-00000000000a', 'Gate Venue',
   29.7604, -95.3698, 500);

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('e1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('e1000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-00000000000a', 'e3000000-0000-0000-0000-0000000000a1', 'staff');

set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000002';
insert into public.time_entries (id, venue_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m)
values ('e5000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-0000000000a1', 29.7604, -95.3698, 12.0);
update public.time_entries
   set is_open = false, clock_out_lat = 29.7604, clock_out_lng = -95.3698, clock_out_accuracy_m = 12.0
 where id = 'e5000000-0000-0000-0000-000000000001';
reset role;

select ok(
  not has_table_privilege('authenticated', 'app_hidden.privilege_gate', 'select')
  and not has_table_privilege('authenticated', 'app_hidden.privilege_gate', 'insert')
  and not has_table_privilege('authenticated', 'app_hidden.privilege_gate', 'update')
  and not has_table_privilege('authenticated', 'app_hidden.privilege_gate', 'delete'),
  'authenticated cannot read or write the privilege gate table'
);

select ok(
  not has_function_privilege('authenticated', 'app_hidden.open_privilege_gate(text)', 'execute')
  and not has_function_privilege('authenticated', 'app_hidden.close_privilege_gate(text)', 'execute')
  and not has_function_privilege('authenticated', 'app_hidden.privilege_gate_is_open(text)', 'execute'),
  'authenticated cannot execute privilege-gate helpers'
);

-- Forging the legacy GUC as authenticated must not open a closed punch for correction.
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select set_config('app.time_entry_correction', 'on', true);
select throws_ok(
  $$ update public.time_entries
        set clock_out_at = now() + interval '1 minute'
      where id = 'e5000000-0000-0000-0000-000000000001' $$,
  '42501', null,
  'set_config(app.time_entry_correction) as authenticated cannot mutate a closed punch'
);
select set_config('app.time_entry_correction', 'off', true);

select set_config('app.contract_signing', 'on', true);
select throws_ok(
  $$ insert into public.crm_contracts (id, venue_id, event_name, status, client_signature_name)
     values ('e8000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-0000000000a1',
             'Forged Sign', 'fully_signed', 'Forged Signer') $$,
  '42501', null,
  'set_config(app.contract_signing) as authenticated cannot forge a signed contract'
);
select set_config('app.contract_signing', 'off', true);
reset role;

-- Legitimate RPC path still works (opens the private gate inside the DEFINER body).
set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.correct_time_entry(
       'e5000000-0000-0000-0000-000000000001',
       (select clock_in_at + interval '30 seconds' from public.time_entries
         where id = 'e5000000-0000-0000-0000-000000000001'),
       null, 'gate regression') $$,
  'correct_time_entry still corrects via the privilege gate'
);
reset role;

select ok(
  (select not is_open from public.time_entries where id = 'e5000000-0000-0000-0000-000000000001'),
  'the corrected punch remains closed'
);

select is(
  (select count(*)::int from app_hidden.privilege_gate
    where backend_pid = pg_backend_pid() and flag = 'time_entry_correction'),
  0,
  'the correction gate is closed after the RPC returns'
);

-- Manager cannot mark an invite accepted without accept_invite (M2).
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('e9000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-0000000000a1',
   'invitee@example.com', 'staff', 'e1000000-0000-0000-0000-000000000001');

set local role authenticated;
set local "request.jwt.claim.sub" to 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ update public.invites set status = 'accepted'
      where id = 'e9000000-0000-0000-0000-000000000001' $$,
  '42501', null,
  'managers cannot move invites pending→accepted outside accept_invite'
);
reset role;

select * from finish();
rollback;
