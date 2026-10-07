-- pgTAP tests for public.venue_roster (supabase/migrations/*_venue_roster_rpc).

begin;
select plan(6);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000002', 'org-a-owner@example.com'),
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000000004', 'Mia Manager'),
  ('00000000-0000-0000-0000-000000000005', 'Sam Staff')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

set local role authenticated;

-- A venue manager (who cannot read other members' memberships rows directly) gets the roster.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004';
select results_eq(
  $$select display_name, role::text from public.venue_roster('20000000-0000-0000-0000-0000000000a1')$$,
  $$values ('Mia Manager', 'venue_manager'), ('Sam Staff', 'staff')$$,
  'a venue manager sees every venue-level member with display names'
);

-- An org owner sees it too.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000002';
select is(
  (select count(*)::int from public.venue_roster('20000000-0000-0000-0000-0000000000a1')),
  2,
  'an organization owner sees the venue roster'
);

-- Staff cannot enumerate their coworkers.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005';
select throws_ok(
  $$select * from public.venue_roster('20000000-0000-0000-0000-0000000000a1')$$,
  '42501', null,
  'staff cannot read the roster'
);

-- Another organization's owner cannot read this venue.
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006';
select throws_ok(
  $$select * from public.venue_roster('20000000-0000-0000-0000-0000000000a1')$$,
  '42501', null,
  'a different organization cannot read the roster'
);

reset role;
set local role anon;
select throws_ok(
  $$select * from public.venue_roster('20000000-0000-0000-0000-0000000000a1')$$,
  '42501', null,
  'anon cannot call it'
);
reset role;

select is(
  (select count(*)::int from information_schema.routine_privileges
    where routine_name = 'venue_roster' and grantee = 'PUBLIC'),
  0,
  'PUBLIC has no execute privilege on venue_roster'
);

select * from finish();
rollback;
