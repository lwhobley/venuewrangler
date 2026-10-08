begin;
select plan(5);

insert into auth.users(id,email) values
  ('00000000-0000-0000-0000-000000000011','manager-receipts@example.com'),
  ('00000000-0000-0000-0000-000000000012','staff-receipts@example.com');
insert into public.organizations(id,name) values
  ('10000000-0000-0000-0000-000000000011','Receipt Org');
insert into public.venues(id,organization_id,name) values
  ('20000000-0000-0000-0000-000000000011',
   '10000000-0000-0000-0000-000000000011','Receipt Venue');
insert into public.memberships(user_id,organization_id,venue_id,role) values
  ('00000000-0000-0000-0000-000000000011',
   '10000000-0000-0000-0000-000000000011',
   '20000000-0000-0000-0000-000000000011','venue_manager'),
  ('00000000-0000-0000-0000-000000000012',
   '10000000-0000-0000-0000-000000000011',
   '20000000-0000-0000-0000-000000000011','staff');
insert into public.notification_events(id,venue_id,audience,kind,title,body) values
  ('30000000-0000-0000-0000-000000000011',
   '20000000-0000-0000-0000-000000000011','venue_staff','general','Team','Update');

set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000011';
select lives_ok(
  $$ select public.mark_notification_read_for_me('30000000-0000-0000-0000-000000000011') $$,
  'manager can read a broadcast for themselves'
);
select ok(
  (select read_at is not null from public.notification_feed_for_me(
    '20000000-0000-0000-0000-000000000011') limit 1),
  'manager feed marks the broadcast read'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000012';
select ok(
  (select read_at is null from public.notification_feed_for_me(
    '20000000-0000-0000-0000-000000000011') limit 1),
  'staff feed remains unread after manager reads the broadcast'
);
select lives_ok(
  $$ select public.mark_notification_read_for_me('30000000-0000-0000-0000-000000000011') $$,
  'staff can read the broadcast for themselves'
);
select ok(
  (select read_at is not null from public.notification_feed_for_me(
    '20000000-0000-0000-0000-000000000011') limit 1),
  'staff feed now marks the broadcast read'
);

select * from finish();
rollback;
