begin;
select plan(15);
insert into auth.users(id,email) values
 ('aa000000-0000-0000-0000-000000000001','hr-manager@example.com'),
 ('aa000000-0000-0000-0000-000000000002','hr-staff@example.com'),
 ('aa000000-0000-0000-0000-000000000003','hr-peer@example.com'),
 ('aa000000-0000-0000-0000-000000000004','hr-outsider@example.com');
insert into public.organizations(id,name) values ('ab000000-0000-0000-0000-000000000001','HR Test');
insert into public.venues(id,organization_id,name) values ('ac000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-000000000001','HR Venue');
insert into public.memberships(user_id,organization_id,venue_id,role) values
 ('aa000000-0000-0000-0000-000000000001','ab000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','venue_manager'),
 ('aa000000-0000-0000-0000-000000000002','ab000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','staff'),
 ('aa000000-0000-0000-0000-000000000003','ab000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-000000000001','venue_manager');
set local role authenticated;
set local "request.jwt.claim.sub" to 'aa000000-0000-0000-0000-000000000002';
select lives_ok($$insert into public.employee_hr_profiles(venue_id,user_id,phone) values ('ac000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000002','555-0100')$$,'staff can create own contact details');
select throws_ok($$update public.employee_hr_profiles set hourly_rate_cents=9900$$,'42501',null,'staff cannot change own pay');
select lives_ok($$update public.employee_hr_profiles set phone=null$$,'staff can clear a contact field');
select is((select phone from public.employee_hr_profiles where user_id=auth.uid()),null,'contact field was cleared');
set local "request.jwt.claim.sub" to 'aa000000-0000-0000-0000-000000000001';
select lives_ok($$update public.employee_hr_profiles set hourly_rate_cents=2500 where user_id='aa000000-0000-0000-0000-000000000002'$$,'manager can set staff pay');
select is((select hourly_rate_cents from public.employee_hr_profiles where user_id='aa000000-0000-0000-0000-000000000002'),2500,'manager pay update persisted');
select throws_ok($$insert into public.employee_hr_profiles(venue_id,user_id,phone) values ('ac000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000003','555')$$,'42501',null,'manager cannot edit another manager');
select throws_ok($$insert into public.staff_photos(venue_id,user_id,storage_path) values ('ac000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000003','ab000000-0000-0000-0000-000000000001/ac000000-0000-0000-0000-000000000001/aa000000-0000-0000-0000-000000000003.photo')$$,'42501',null,'manager cannot replace a peer photo');
select lives_ok($$insert into public.staff_photos(venue_id,user_id,storage_path) values ('ac000000-0000-0000-0000-000000000001','aa000000-0000-0000-0000-000000000002','ab000000-0000-0000-0000-000000000001/ac000000-0000-0000-0000-000000000001/aa000000-0000-0000-0000-000000000002.photo')$$,'manager can add a staff photo');
select throws_ok($$update public.staff_photos set storage_path='ab000000-0000-0000-0000-000000000001/ac000000-0000-0000-0000-000000000001/aa000000-0000-0000-0000-000000000001.photo'$$,'42501',null,'photo metadata cannot point at another user');
set local "request.jwt.claim.sub" to 'aa000000-0000-0000-0000-000000000003';
select is((select count(*)::integer from public.staff_photos),1,'team can see identity photo metadata');
select is((select count(*)::integer from public.employee_hr_profiles),1,'authorized peer manager can read subordinate HR details');
set local "request.jwt.claim.sub" to 'aa000000-0000-0000-0000-000000000004';
select is((select count(*)::integer from public.employee_hr_profiles),0,'outsider cannot read HR');
select is((select count(*)::integer from public.staff_photos),0,'outsider cannot read photo metadata');
reset role;
select is((select public from storage.buckets where id='profile-photos'),false,'photos bucket is private');
select * from finish();
rollback;
