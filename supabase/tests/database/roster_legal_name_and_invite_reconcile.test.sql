-- pgTAP: roster display hides HR legal_name; prepare_staff_invite reconciles role/name.
begin;
select plan(6);

insert into auth.users (id, email) values
  ('f1000000-0000-0000-0000-000000000001', 'owner-low@example.test'),
  ('f1000000-0000-0000-0000-000000000002', 'staff-low@example.test');

insert into public.organizations (id, name) values
  ('f2000000-0000-0000-0000-00000000000a', 'Low Org');

insert into public.venues (id, organization_id, name) values
  ('f3000000-0000-0000-0000-0000000000a1', 'f2000000-0000-0000-0000-00000000000a', 'Low Venue');

-- handle_new_user creates bare profiles; set display names for the roster assertions.
update public.profiles
set display_name = 'Owner Display'
where id = 'f1000000-0000-0000-0000-000000000001';
update public.profiles
set display_name = 'Staff Display'
where id = 'f1000000-0000-0000-0000-000000000002';

insert into public.memberships (user_id, organization_id, venue_id, role) values
  (
    'f1000000-0000-0000-0000-000000000001',
    'f2000000-0000-0000-0000-00000000000a',
    null,
    'organization_owner'
  ),
  (
    'f1000000-0000-0000-0000-000000000002',
    'f2000000-0000-0000-0000-00000000000a',
    'f3000000-0000-0000-0000-0000000000a1',
    'staff'
  );

insert into public.employee_hr_profiles (venue_id, user_id, legal_name, preferred_name) values
  (
    'f3000000-0000-0000-0000-0000000000a1',
    'f1000000-0000-0000-0000-000000000002',
    'Legal Name Hidden',
    null
  );

set local role authenticated;
set local "request.jwt.claim.sub" = 'f1000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  (
    select r.display_name
    from public.venue_schedule_roster('f3000000-0000-0000-0000-0000000000a1') r
    where r.user_id = 'f1000000-0000-0000-0000-000000000002'
  ),
  'Staff Display',
  'schedule roster falls back to profiles.display_name, not HR legal_name'
);

select is(
  (
    select r.display_name
    from public.venue_roster('f3000000-0000-0000-0000-0000000000a1') r
    where r.user_id = 'f1000000-0000-0000-0000-000000000002'
  ),
  'Staff Display',
  'manager venue_roster also omits HR legal_name from staff_display_name'
);

-- Preferred name still wins when set (as the owner / service path).
reset role;
update public.employee_hr_profiles
set preferred_name = 'Preferred Nick'
where user_id = 'f1000000-0000-0000-0000-000000000002'
  and venue_id = 'f3000000-0000-0000-0000-0000000000a1';

set local role authenticated;
set local "request.jwt.claim.sub" = 'f1000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.role" = 'authenticated';

select is(
  (
    select r.display_name
    from public.venue_schedule_roster('f3000000-0000-0000-0000-0000000000a1') r
    where r.user_id = 'f1000000-0000-0000-0000-000000000002'
  ),
  'Preferred Nick',
  'preferred_name still preferred over profiles.display_name'
);

-- Invite reconcile: pending staff invite updated to supervisor + new display name.
select public.prepare_staff_invite(
  'f3000000-0000-0000-0000-0000000000a1',
  'hire-low@example.test',
  'staff',
  'Old Name'
);

select is(
  (
    select role::text
    from public.invites
    where email = 'hire-low@example.test' and status = 'pending'
  ),
  'staff',
  'initial invite role is staff'
);

select public.prepare_staff_invite(
  'f3000000-0000-0000-0000-0000000000a1',
  'hire-low@example.test',
  'supervisor',
  'New Name'
);

select is(
  (
    select role::text
    from public.invites
    where email = 'hire-low@example.test' and status = 'pending'
  ),
  'supervisor',
  're-invite reconciles role on the existing pending row'
);

select is(
  (
    select display_name
    from public.invites
    where email = 'hire-low@example.test' and status = 'pending'
  ),
  'New Name',
  're-invite reconciles display_name on the existing pending row'
);

select * from finish();
rollback;
