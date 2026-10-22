-- pgTAP tests for 20261022130000_beo_cancel_restore_and_hold_sync.sql (launch review D4, D5, U7).
-- Fixtures: Org A / Venue A1 with a manager (b4), a supervisor (b7) and a staff member (b5).

begin;
select plan(34);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000b4', 'beo-manager@example.com'),
  ('00000000-0000-0000-0000-0000000000b5', 'beo-staff@example.com'),
  ('00000000-0000-0000-0000-0000000000b7', 'beo-supervisor@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000000ba', 'Org BEO');

insert into public.venues (id, organization_id, name, timezone) values
  ('20000000-0000-0000-0000-0000000000ba', '10000000-0000-0000-0000-0000000000ba', 'Venue BEO', 'America/Chicago');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-0000000000b4', '10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'venue_manager'),
  ('00000000-0000-0000-0000-0000000000b5', '10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'staff'),
  ('00000000-0000-0000-0000-0000000000b7', '10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'supervisor');

-- Runs a statement and returns the error it raised (null if it succeeded), so a test can look
-- at the message and DETAIL rather than only the SQLSTATE.
create function pg_temp.capture_error(p_sql text)
returns jsonb
language plpgsql
as $$
declare
  v_state text;
  v_message text;
  v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_message = message_text,
    v_detail = pg_exception_detail;
  return jsonb_build_object('code', v_state, 'message', v_message, 'detail', v_detail);
end;
$$;
grant execute on function pg_temp.capture_error(text) to authenticated;

-- The Whitmore party: confirmed, 45 guests, its hold in the book.
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
insert into public.crm_beos (id, venue_id, event_name, guest_count, event_date, status) values
  ('c1000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000ba',
   'Whitmore & Associates Holiday Party', 45, '2030-12-12 01:00+00', 'confirmed');

select is(
  (select status from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: confirming the party creates its hold'
);

-- ---------------------------------------------------------------------------
-- D4. Cancel from CRM, then restore
-- ---------------------------------------------------------------------------
update public.crm_beos set status = 'cancelled' where id = 'c1000000-0000-0000-0000-000000000001';

select is(
  (select status from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001'),
  'cancelled',
  'D4: cancelling the event cancels its booking'
);
select is(
  (select status_before_cancel from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: the cancelled event remembers it was confirmed'
);
select isnt(
  (select cancelled_at from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  null,
  'D4: the cancellation time is recorded'
);

update public.crm_beos set status_before_cancel = 'draft', internal_notes = 'touch'
  where id = 'c1000000-0000-0000-0000-000000000001';
select is(
  (select status_before_cancel from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: clients cannot rewrite the remembered status'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
select throws_ok(
  $$ select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'D4: staff cannot restore an event'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select is(
  public.restore_crm_beo('c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: a manager restores the event to confirmed'
);
select is(
  (select status from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: restoring the event restores the same booking'
);
select is(
  (select count(*)::int from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001'),
  1,
  'D4: restoring does not create a second booking'
);
select is(
  (select cancelled_at from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  null,
  'D4: a restored event is no longer marked cancelled'
);
select throws_ok(
  $$ select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001') $$,
  '22023',
  null,
  'D4: an event that is not cancelled cannot be restored'
);

-- Restore re-checks the window: a dinner booked into the freed night blocks it.
update public.crm_beos set status = 'cancelled' where id = 'c1000000-0000-0000-0000-000000000001';
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
insert into public.reservations (id, organization_id, venue_id, guest_name, party_size, reservation_time, duration_minutes)
values ('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-0000000000ba',
        '20000000-0000-0000-0000-0000000000ba', 'Hannah Brooks', 4, '2030-12-12 01:30+00', 90);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select throws_ok(
  $$ select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001') $$,
  '23505',
  null,
  'D4: an event cannot be restored over a booking made since it was cancelled'
);
select is(
  (select status from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'cancelled',
  'D4: a refused restore leaves the event cancelled'
);
select ok(
  (pg_temp.capture_error($$ select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001') $$)
    ->> 'detail')::jsonb -> 'conflicts' @> '[{"kind": "reservation", "name": "Hannah Brooks", "party_size": 4}]',
  'U7: the refused restore names the booking in the way'
);

-- Free the night again for the next blocks.
update public.reservations set status = 'cancelled' where id = 'e1000000-0000-0000-0000-000000000001';
select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001');

-- Past events cannot be restored.
reset role;
insert into public.crm_beos (id, organization_id, venue_id, event_name, event_date, status, status_before_cancel) values
  ('c1000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-0000000000ba',
   '20000000-0000-0000-0000-0000000000ba', 'Last month', now() - interval '30 days', 'cancelled', null);
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select throws_ok(
  $$ select public.restore_crm_beo('c1000000-0000-0000-0000-000000000002') $$,
  '22023',
  null,
  'D4: an event whose date has passed cannot be restored'
);

-- ---------------------------------------------------------------------------
-- D4. Cancel and restore from the reservation book
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b7';
select throws_ok(
  $$ update public.reservations set status = 'cancelled'
      where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'D4: a supervisor cannot cancel a private event''s booking on its own'
);
select throws_ok(
  $$ update public.reservations set reservation_time = reservation_time + interval '1 hour'
      where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'D4: a private event''s booking cannot be moved from the book'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
select lives_ok(
  $$ update public.reservations set status = 'seated'
      where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  'D4: staff can still seat the party'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
update public.reservations set status = 'cancelled'
  where beo_id = 'c1000000-0000-0000-0000-000000000001';
select is(
  (select status from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'cancelled',
  'D4: a manager cancelling the booking cancels the event'
);
select is(
  (select status_before_cancel from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: the event cancelled from the book can still be restored to confirmed'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b7';
select throws_ok(
  $$ update public.reservations set status = 'confirmed'
      where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'D4: a supervisor cannot restore a private event''s booking'
);

set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
update public.reservations set status = 'confirmed'
  where beo_id = 'c1000000-0000-0000-0000-000000000001';
select is(
  (select status from public.crm_beos where id = 'c1000000-0000-0000-0000-000000000001'),
  'confirmed',
  'D4: a manager restoring the booking restores the event'
);

select throws_ok(
  $$ delete from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'D4: a confirmed event''s booking cannot be deleted'
);

-- A book-side restore re-checks the window too.
update public.crm_beos set status = 'cancelled' where id = 'c1000000-0000-0000-0000-000000000001';
update public.reservations set status = 'confirmed' where id = 'e1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$ update public.reservations set status = 'confirmed'
      where beo_id = 'c1000000-0000-0000-0000-000000000001' $$,
  '23505',
  null,
  'D4: restoring from the book is refused when the night has been booked'
);
select is(
  (select status from public.reservations where beo_id = 'c1000000-0000-0000-0000-000000000001'),
  'cancelled',
  'D4: the refused book-side restore leaves the booking cancelled'
);
update public.reservations set status = 'cancelled' where id = 'e1000000-0000-0000-0000-000000000001';
select public.restore_crm_beo('c1000000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------
-- U7. Conflict errors say what is in the way
-- ---------------------------------------------------------------------------
-- The Patel birthday, blocked by two ordinary dinners on its night.
insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time, duration_minutes) values
  ('10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'Lee', 2, '2030-10-25 00:30+00', 90),
  ('10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'Okafor', 4, '2030-10-25 02:00+00', 90);
insert into public.crm_beos (id, venue_id, event_name, guest_count, event_date, status) values
  ('c1000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000ba',
   'Patel Birthday', 20, '2030-10-25 00:00+00', 'draft');

select is(
  pg_temp.capture_error($$ update public.crm_beos set status = 'confirmed'
                           where id = 'c1000000-0000-0000-0000-000000000003' $$) ->> 'code',
  '23505',
  'U7: confirming over dinners is refused'
);
select ok(
  pg_temp.capture_error($$ update public.crm_beos set status = 'confirmed'
                           where id = 'c1000000-0000-0000-0000-000000000003' $$) ->> 'message'
    like 'reservation_hold_conflict: 2 reservations overlap%',
  'U7: the message says reservations, not another event'
);
select is(
  array(
    select c ->> 'kind' || ':' || (c ->> 'name') || ':' || (c ->> 'party_size') || ':'
           || extract(epoch from (c ->> 'starts_at')::timestamptz)::bigint
      from jsonb_array_elements(
        (pg_temp.capture_error($$ update public.crm_beos set status = 'confirmed'
                                  where id = 'c1000000-0000-0000-0000-000000000003' $$) ->> 'detail')::jsonb
          -> 'conflicts'
      ) c
  ),
  array[
    'reservation:Lee:2:' || extract(epoch from timestamptz '2030-10-25 00:30+00')::bigint,
    'reservation:Okafor:4:' || extract(epoch from timestamptz '2030-10-25 02:00+00')::bigint
  ],
  'U7: the detail lists each booking with its time, earliest first'
);
select is(
  ((pg_temp.capture_error($$ update public.crm_beos set status = 'confirmed'
                             where id = 'c1000000-0000-0000-0000-000000000003' $$) ->> 'detail')::jsonb
     ->> 'total')::int,
  2,
  'U7: the detail counts them'
);

-- A booking over the Whitmore party: a manager is told the event's CRM name, staff the name its
-- booking shows in the reservation book (here the lead's name, not the CRM event name).
reset role;
update public.reservations set guest_name = 'Caroline Whitmore'
  where beo_id = 'c1000000-0000-0000-0000-000000000001';
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b4';
select ok(
  (pg_temp.capture_error($$ insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time)
     values ('10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'Walk-in', 2, '2030-12-12 02:00+00') $$)
    ->> 'detail')::jsonb -> 'conflicts' @> '[{"kind": "event", "name": "Whitmore & Associates Holiday Party", "party_size": 45}]',
  'U7: a manager is told which event holds the time'
);
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
select ok(
  (pg_temp.capture_error($$ insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time)
     values ('10000000-0000-0000-0000-0000000000ba', '20000000-0000-0000-0000-0000000000ba', 'Walk-in', 2, '2030-12-12 02:00+00') $$)
    ->> 'detail')::jsonb -> 'conflicts' @> '[{"kind": "event", "name": "Caroline Whitmore", "party_size": 45}]',
  'U7: staff are told the event''s booking as the book shows it, not the CRM event name'
);

-- ---------------------------------------------------------------------------
-- D5. Event notes are readable by the team; BEO money stays manager-only
-- ---------------------------------------------------------------------------
reset role;
insert into public.events (id, venue_id, name, start_time, end_time, notes) values
  ('e5000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000ba', 'Late jazz set with the Lloyd Trio',
   '2030-10-21 04:30+00', '2030-10-21 07:30+00', 'Band loads in at 9:30 through the patio gate.');
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000b5';
select is(
  (select notes from public.events where id = 'e5000000-0000-0000-0000-000000000001'),
  'Band loads in at 9:30 through the patio gate.',
  'D5: staff can read an event''s notes'
);
select is(
  (select count(*)::int from public.crm_beos where venue_id = '20000000-0000-0000-0000-0000000000ba'),
  0,
  'D5: staff still cannot read BEOs'
);
select is(
  (select count(*)::int from public.crm_beo_charges where venue_id = '20000000-0000-0000-0000-0000000000ba'),
  0,
  'D5: staff still cannot read BEO charges'
);

select * from finish();
rollback;
