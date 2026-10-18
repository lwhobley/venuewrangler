-- pgTAP tests for least-privilege reads (20261017150000_least_privilege_reads.sql).
-- Fixture: venue A1 with manager M, supervisor S, staff R (reporter) and staff T; org B owner X.

begin;
select plan(15);

insert into auth.users (id, email) values
  ('f1000000-0000-0000-0000-000000000001', 'm@example.com'),
  ('f1000000-0000-0000-0000-000000000002', 's@example.com'),
  ('f1000000-0000-0000-0000-000000000003', 'r@example.com'),
  ('f1000000-0000-0000-0000-000000000004', 't@example.com'),
  ('f1000000-0000-0000-0000-000000000005', 'x@example.com');
insert into public.organizations (id, name) values
  ('f2000000-0000-0000-0000-00000000000a', 'Org A'),
  ('f2000000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name) values
  ('f3000000-0000-0000-0000-0000000000a1', 'f2000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('f3000000-0000-0000-0000-0000000000b1', 'f2000000-0000-0000-0000-00000000000b', 'Venue B1');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('f1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-00000000000a', 'f3000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('f1000000-0000-0000-0000-000000000002', 'f2000000-0000-0000-0000-00000000000a', 'f3000000-0000-0000-0000-0000000000a1', 'supervisor'),
  ('f1000000-0000-0000-0000-000000000003', 'f2000000-0000-0000-0000-00000000000a', 'f3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('f1000000-0000-0000-0000-000000000004', 'f2000000-0000-0000-0000-00000000000a', 'f3000000-0000-0000-0000-0000000000a1', 'staff'),
  ('f1000000-0000-0000-0000-000000000005', 'f2000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- Staff R reports an incident with a photo; T reports a different one.
set local role authenticated;
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000003';
insert into public.incidents (id, venue_id, title, severity)
  values ('f4000000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-0000000000a1', 'R reports', 'low');
insert into public.incident_attachments (id, incident_id, storage_path)
  values ('f5000000-0000-0000-0000-000000000001', 'f4000000-0000-0000-0000-000000000001',
          'f2000000-0000-0000-0000-00000000000a/f3000000-0000-0000-0000-0000000000a1/r-photo.jpg');
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000004';
insert into public.incidents (id, venue_id, title, severity)
  values ('f4000000-0000-0000-0000-000000000002', 'f3000000-0000-0000-0000-0000000000a1', 'T reports', 'low');

-- A supervisor adds a photo to R's incident.
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000002';
insert into public.incident_attachments (id, incident_id, storage_path)
  values ('f5000000-0000-0000-0000-000000000002', 'f4000000-0000-0000-0000-000000000001',
          'f2000000-0000-0000-0000-00000000000a/f3000000-0000-0000-0000-0000000000a1/s-photo.jpg');

-- Reporters see only their own.
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000003';
select results_eq($$ select title from public.incidents order by title $$, $$ values ('R reports'::text) $$,
  'a reporter sees only the incidents they reported');
select is((select count(*)::int from public.incident_attachments), 2,
  'the reporter sees every photo on their own incident, including a supervisor''s');
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000004';
select results_eq($$ select title from public.incidents order by title $$, $$ values ('T reports'::text) $$,
  'another staff member sees only their own report');
select is((select count(*)::int from public.incident_attachments), 0,
  'and none of a colleague''s photos');

-- Supervisors and above see everything in their venue.
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.incidents), 2, 'a supervisor sees every incident in the venue');
select is((select count(*)::int from public.incident_attachments), 2, 'and every photo');
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.incidents), 2, 'a venue manager sees every incident in the venue');

-- Another organization sees nothing.
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000005';
select is((select count(*)::int from public.incidents), 0, 'another organization''s owner sees none');
select is((select count(*)::int from public.incident_attachments), 0, 'nor any photos');

-- A reporter can still edit their own open incident (update policy unchanged).
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000003';
select lives_ok($$ update public.incidents set title = 'R reports (edited)' where id = 'f4000000-0000-0000-0000-000000000001' $$,
  'the reporter can still edit their open incident');
select is((select title from public.incidents where id = 'f4000000-0000-0000-0000-000000000001'), 'R reports (edited)',
  'and the edit is visible to them');

-- POS checks: supervisors and above only.
reset role;
insert into public.pos_checks (id, venue_id, organization_id, provider, external_check_id, opened_at, subtotal_cents, total_cents)
values ('f6000000-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-0000000000a1', 'f2000000-0000-0000-0000-00000000000a',
        'toast', 'chk-lp', now(), 100, 110);
set local role authenticated;
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000003';
select is((select count(*)::int from public.pos_checks), 0, 'staff cannot read POS checks');
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.pos_checks), 1, 'a supervisor can read POS checks');
set local "request.jwt.claim.sub" to 'f1000000-0000-0000-0000-000000000005';
select is((select count(*)::int from public.pos_checks), 0, 'another organization cannot read POS checks');
reset role;
select ok(true, 'fixture completed');

select * from finish();
rollback;
