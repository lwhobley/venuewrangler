-- Runs after migrations against a disposable database only. Also usable in Supabase CI.
\set ON_ERROR_STOP on
begin;
create function pg_temp.expect_state(statement text, expected text) returns void
language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlstate = expected then return; end if;
    raise;
  end;
  raise exception 'Expected SQLSTATE %, statement succeeded: %', expected, statement;
end $$;
grant execute on function pg_temp.expect_state(text,text) to authenticated;

insert into auth.users(id,email,email_confirmed_at) values
 ('e1000000-0000-0000-0000-000000000001','launch-manager@example.test',now()),
 ('e1000000-0000-0000-0000-000000000002','launch-staff@example.test',now()),
 ('e1000000-0000-0000-0000-000000000003','launch-cover@example.test',now()),
 ('e1000000-0000-0000-0000-000000000004','launch-other@example.test',now());
insert into public.organizations(id,name) values
 ('e2000000-0000-0000-0000-000000000001','Launch A'),
 ('e2000000-0000-0000-0000-000000000002','Launch B');
insert into public.venues(id,organization_id,name,timezone) values
 ('e3000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','Launch A','America/Chicago'),
 ('e3000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000002','Launch B','UTC');
insert into public.memberships(user_id,organization_id,venue_id,role) values
 ('e1000000-0000-0000-0000-000000000001','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','venue_manager'),
 ('e1000000-0000-0000-0000-000000000002','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','staff'),
 ('e1000000-0000-0000-0000-000000000003','e2000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','staff'),
 ('e1000000-0000-0000-0000-000000000004','e2000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000002','venue_manager');

set local role authenticated;
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000002';
select pg_temp.expect_state($q$select public.set_venue_location('e3000000-0000-0000-0000-000000000001','Here',41,-87,150)$q$, '42501');
select pg_temp.expect_state($q$insert into public.time_entries(venue_id,clock_in_lat,clock_in_lng,clock_in_accuracy_m) values('e3000000-0000-0000-0000-000000000001',41,-87,12)$q$,'42501');
select pg_temp.expect_state($q$select public.prepare_staff_invite('e3000000-0000-0000-0000-000000000001','someone@example.test','staff')$q$,'42501');

set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000001';
select pg_temp.expect_state($q$select public.set_venue_location('e3000000-0000-0000-0000-000000000002','There',41,-87,150)$q$, '42501');
select pg_temp.expect_state($q$select public.set_venue_location('e3000000-0000-0000-0000-000000000001','Here','NaN',-87,150)$q$, '22023');
select public.set_venue_location('e3000000-0000-0000-0000-000000000001','Venue entrance',41,-87,150);
select public.prepare_staff_invite('e3000000-0000-0000-0000-000000000001','new@example.test','staff','New Hire');
reset role;
-- The old invite is expired but still pending, as in the launch review reproduction.
delete from public.invites where email = 'new@example.test';
insert into public.invites(venue_id,email,role,expires_at) values('e3000000-0000-0000-0000-000000000001','new@example.test','staff',now()-interval '1 day');
set local role authenticated;
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000001';
select public.prepare_staff_invite('e3000000-0000-0000-0000-000000000001','new@example.test','staff','New Hire');
reset role;
do $$ begin
  assert (select count(*) = 1 from public.invites where email='new@example.test' and status='pending' and expires_at > now()), 'Replacement invite must be usable';
  assert (select count(*) = 1 from public.invites where email='new@example.test' and status='revoked'), 'Expired invite must be retired';
end $$;

set local role authenticated;
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000002';
select pg_temp.expect_state($q$insert into public.time_entries(venue_id,clock_in_lat,clock_in_lng,clock_in_accuracy_m) values('e3000000-0000-0000-0000-000000000001',42,-87,12)$q$,'42501');
insert into public.time_entries(venue_id,clock_in_lat,clock_in_lng,clock_in_accuracy_m)
 values('e3000000-0000-0000-0000-000000000001',41,-87,12);

set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000001';
insert into public.shifts(id,venue_id,staff_id,start_time,end_time) values
 ('e4000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002',now()+interval '1 day',now()+interval '1 day 4 hours'),
 ('e4000000-0000-0000-0000-000000000002','e3000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000003',now()+interval '1 day',now()+interval '1 day 4 hours');
select pg_temp.expect_state($q$insert into public.shifts(venue_id,staff_id,start_time,end_time) values('e3000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002',now()+interval '1 day 1 hour',now()+interval '1 day 2 hours')$q$, '23P01');
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000002';
insert into public.shift_swaps(id,shift_id) values('e5000000-0000-0000-0000-000000000001','e4000000-0000-0000-0000-000000000001');
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000003';
select pg_temp.expect_state($q$update public.shift_swaps set status='accepted',accepted_by='e1000000-0000-0000-0000-000000000003' where id='e5000000-0000-0000-0000-000000000001'$q$, '23P01');
reset role;
do $$ begin
  assert (select status = 'pending' from public.shift_swaps where id='e5000000-0000-0000-0000-000000000001'), 'Rejected swap must remain pending';
  assert (select staff_id = 'e1000000-0000-0000-0000-000000000002' from public.shifts where id='e4000000-0000-0000-0000-000000000001'), 'Rejected swap must preserve assignment';
end $$;

set local role authenticated;
set local "request.jwt.claim.sub" = 'e1000000-0000-0000-0000-000000000001';
insert into public.employee_hr_profiles(venue_id,user_id,preferred_name) values
 ('e3000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000002','Camila Reyes');
do $$ begin
  assert (select display_name = 'Camila Reyes' from public.venue_roster('e3000000-0000-0000-0000-000000000001') where user_id='e1000000-0000-0000-0000-000000000002');
end $$;
insert into public.crm_beos(id,venue_id,event_name,event_date,guest_count,status) values
 ('e6000000-0000-0000-0000-000000000001','e3000000-0000-0000-0000-000000000001','Launch Party',now()+interval '100 days',45,'confirmed');
update public.reservations set status='cancelled' where beo_id='e6000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select status = 'cancelled' from public.crm_beos where id='e6000000-0000-0000-0000-000000000001'), 'Reservation cancellation must cancel event';
end $$;
update public.crm_beos set status='draft' where id='e6000000-0000-0000-0000-000000000001';
update public.crm_beos set status='confirmed' where id='e6000000-0000-0000-0000-000000000001';
do $$ begin
  assert (select status = 'confirmed' from public.reservations where beo_id='e6000000-0000-0000-0000-000000000001'), 'Restoring event must restore reservation';
end $$;
reset role;
rollback;
\echo Launch review authorization, location, invite, overlap, name and cancellation assertions passed.
