begin;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000014', 'beo-manager@example.com'),
  ('00000000-0000-0000-0000-000000000015', 'beo-staff@example.com'),
  ('00000000-0000-0000-0000-000000000016', 'other-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000001a', 'BEO Org A'),
  ('10000000-0000-0000-0000-00000000001b', 'BEO Org B');
insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000001a1', '10000000-0000-0000-0000-00000000001a', 'BEO Venue A'),
  ('20000000-0000-0000-0000-0000000001b1', '10000000-0000-0000-0000-00000000001b', 'BEO Venue B');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000014', '10000000-0000-0000-0000-00000000001a', '20000000-0000-0000-0000-0000000001a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000015', '10000000-0000-0000-0000-00000000001a', '20000000-0000-0000-0000-0000000001a1', 'staff'),
  ('00000000-0000-0000-0000-000000000016', '10000000-0000-0000-0000-00000000001b', null, 'organization_owner');

insert into public.crm_beos (id, venue_id, event_name) values
  ('70000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-0000000001a1', 'Dinner A'),
  ('70000000-0000-0000-0000-000000000012', '20000000-0000-0000-0000-0000000001b1', 'Dinner B');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000014';
select lives_ok(
  $$ insert into public.crm_beo_charges (beo_id, venue_id, description, category, amount_cents)
     values ('70000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-0000000001a1', 'Dinner package', 'food', 250000) $$,
  'venue manager can add an itemized charge'
);
select is((select count(*)::int from public.crm_beo_charges), 1,
  'venue manager sees the charge');
select throws_ok(
  $$ insert into public.crm_beo_charges (beo_id, venue_id, description, category, amount_cents)
     values ('70000000-0000-0000-0000-000000000012', '20000000-0000-0000-0000-0000000001b1', 'Other venue', 'room', 10000) $$,
  '42501', null, 'manager cannot add charges to another venue'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000015';
select is((select count(*)::int from public.crm_beo_charges), 0,
  'staff cannot read charge amounts');
select throws_ok(
  $$ insert into public.crm_beo_charges (beo_id, venue_id, description, category, amount_cents)
     values ('70000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-0000000001a1', 'Unauthorized', 'food', 10000) $$,
  '42501', null, 'staff cannot add charges'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000016';
select is((select count(*)::int from public.crm_beo_charges), 0,
  'other organization cannot read charge amounts');
select throws_ok(
  $$ insert into public.crm_beo_charges (beo_id, venue_id, description, category, amount_cents)
     values ('70000000-0000-0000-0000-000000000011', '20000000-0000-0000-0000-0000000001b1', 'Mismatch', 'other', 10000) $$,
  '23503', null, 'charge venue must match its BEO venue'
);

select * from finish();
rollback;
