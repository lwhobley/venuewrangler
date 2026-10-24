-- pgTAP tests for the "Ask about your data" metric catalogue
-- (20261024120001_ask_data_helpers.sql, 20261024120002_ask_data_metrics.sql).
-- Fixture: org A with venue A1 (America/Chicago) and venue A2 (UTC); org B with venue B1.
-- A1: manager M, supervisor S, staff T and T2. A2: manager M2. Org A owner O. Org B owner X.
-- Day boundaries: Chicago is UTC-5 in October 2026, so 04:30Z on the 17th is 23:30 on the 16th.

begin;
select plan(70);

insert into auth.users (id, email) values
  ('a5100000-0000-0000-0000-000000000001', 'm@example.com'),
  ('a5100000-0000-0000-0000-000000000002', 's@example.com'),
  ('a5100000-0000-0000-0000-000000000003', 't@example.com'),
  ('a5100000-0000-0000-0000-000000000004', 't2@example.com'),
  ('a5100000-0000-0000-0000-000000000005', 'm2@example.com'),
  ('a5100000-0000-0000-0000-000000000006', 'x@example.com'),
  ('a5100000-0000-0000-0000-000000000007', 'o@example.com'),
  ('a5100000-0000-0000-0000-000000000008', 'pref@example.com'),
  ('a5100000-0000-0000-0000-000000000009', 'noname@example.com');
insert into public.profiles (id) select id from auth.users where id::text like 'a5100000-%'
on conflict (id) do nothing;
update public.profiles set display_name = 'Tess Tester' where id = 'a5100000-0000-0000-0000-000000000003';
update public.profiles set display_name = 'Tom Two' where id = 'a5100000-0000-0000-0000-000000000004';
update public.profiles set display_name = 'Legacy Name' where id = 'a5100000-0000-0000-0000-000000000008';
update public.profiles set display_name = null where id = 'a5100000-0000-0000-0000-000000000009';
update public.profiles set display_name = 'Mia Elsewhere' where id = 'a5100000-0000-0000-0000-000000000005';

insert into public.organizations (id, name) values
  ('a5200000-0000-0000-0000-00000000000a', 'Org A'),
  ('a5200000-0000-0000-0000-00000000000b', 'Org B');
insert into public.venues (id, organization_id, name, timezone) values
  ('a5300000-0000-0000-0000-0000000000a1', 'a5200000-0000-0000-0000-00000000000a', 'Marigold', 'America/Chicago'),
  ('a5300000-0000-0000-0000-0000000000a2', 'a5200000-0000-0000-0000-00000000000a', 'Fulton', 'UTC'),
  ('a5300000-0000-0000-0000-0000000000b1', 'a5200000-0000-0000-0000-00000000000b', 'Other', 'UTC');
insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('a5100000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('a5100000-0000-0000-0000-000000000002', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'supervisor'),
  ('a5100000-0000-0000-0000-000000000003', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'staff'),
  ('a5100000-0000-0000-0000-000000000004', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'staff'),
  ('a5100000-0000-0000-0000-000000000005', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a2', 'venue_manager'),
  ('a5100000-0000-0000-0000-000000000006', 'a5200000-0000-0000-0000-00000000000b', null, 'organization_owner'),
  ('a5100000-0000-0000-0000-000000000007', 'a5200000-0000-0000-0000-00000000000a', null, 'organization_owner'),
  ('a5100000-0000-0000-0000-000000000008', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'staff'),
  ('a5100000-0000-0000-0000-000000000009', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'staff');

-- ---------------------------------------------------------------------------
-- Seed data (as the table owner; triggers off so the fixtures can be exact).
-- ---------------------------------------------------------------------------
set local session_replication_role = replica;

-- Reservations at A1 (Chicago). r1/r2 straddle local midnight between the 16th and 17th.
insert into public.reservations (organization_id, venue_id, guest_name, guest_phone, guest_email, party_size, reservation_time, status, notes) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Guest One', '555-0101', 'g1@example.com', 4, '2026-10-17 04:30:00+00', 'completed', 'allergic to nuts'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Guest Two', '555-0102', 'g2@example.com', 2, '2026-10-17 05:30:00+00', 'seated', 'VIP'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Guest Three', '555-0103', 'g3@example.com', 6, '2026-10-18 00:00:00+00', 'no_show', null),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Guest Four', '555-0104', 'g4@example.com', 3, '2026-10-18 01:00:00+00', 'cancelled', null),
  -- another venue's booking on the same day must never be counted
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a2', 'Elsewhere', null, null, 50, '2026-10-17 18:00:00+00', 'confirmed', null);
-- 60 single-cover days in January for the row-cap tests.
insert into public.reservations (organization_id, venue_id, guest_name, party_size, reservation_time, status)
select 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Cap ' || g, 1,
       timestamptz '2026-01-01 18:00:00+00' + g * interval '1 day', 'confirmed'
  from generate_series(0, 59) g;

-- Time entries. T: Mon-Fri 9:00-18:00 local with a 30 min unpaid and a 15 min paid break
-- (8.5 h each), plus 4 h the next Monday. T2: 6 h that starts at 22:00 local on the 13th
-- (03:00Z on the 14th), a punch left open since the 20th, and one opened two hours ago.
insert into public.time_entries (organization_id, venue_id, user_id, clock_in_at, clock_in_lat, clock_in_lng, clock_in_accuracy_m,
                                 clock_out_at, is_open, breaks)
select 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1',
       'a5100000-0000-0000-0000-000000000003', cin, 41.0, -87.0, 10, cin + interval '9 hours', false,
       jsonb_build_array(
         jsonb_build_object('type', 'unpaid', 'start_at', cin + interval '3 hours', 'end_at', cin + interval '3 hours 30 minutes'),
         jsonb_build_object('type', 'paid', 'start_at', cin + interval '5 hours', 'end_at', cin + interval '5 hours 15 minutes'))
  from (select timestamptz '2026-10-12 14:00:00+00' + g * interval '1 day' as cin from generate_series(0, 4) g) d;
insert into public.time_entries (organization_id, venue_id, user_id, clock_in_at, clock_in_lat, clock_in_lng, clock_in_accuracy_m, clock_out_at, is_open) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000003', '2026-10-19 14:00:00+00', 41.0, -87.0, 10, '2026-10-19 18:00:00+00', false),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000004', '2026-10-14 03:00:00+00', 41.0, -87.0, 10, '2026-10-14 09:00:00+00', false),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000004', '2026-10-20 14:00:00+00', 41.0, -87.0, 10, null, true),
  -- another venue's punch (its manager's name must never show in A1 answers)
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a2', 'a5100000-0000-0000-0000-000000000005', '2026-10-13 14:00:00+00', 41.0, -87.0, 10, '2026-10-13 18:00:00+00', false);
insert into public.time_entries (organization_id, venue_id, user_id, clock_in_at, clock_in_lat, clock_in_lng, clock_in_accuracy_m, is_open) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000003', now() - interval '2 hours', 41.0, -87.0, 10, true);

-- Shifts: T 6 h + 4 h, an unassigned 4 h, a cancelled 8 h for T, T2 8 h.
insert into public.shifts (organization_id, venue_id, staff_id, start_time, end_time, status) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000003', '2026-10-14 22:00:00+00', '2026-10-15 04:00:00+00', 'scheduled'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000003', '2026-10-15 22:00:00+00', '2026-10-16 02:00:00+00', 'scheduled'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', null, '2026-10-15 23:00:00+00', '2026-10-16 03:00:00+00', 'scheduled'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000003', '2026-10-14 14:00:00+00', '2026-10-14 22:00:00+00', 'cancelled'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000004', '2026-10-16 17:00:00+00', '2026-10-17 01:00:00+00', 'scheduled');

-- Name resolution (app_hidden.staff_display_name): a manager-entered preferred name wins; a person
-- with no name at all is "Unnamed team member", never their email. Shifts far from the rest.
insert into public.employee_hr_profiles (venue_id, user_id, preferred_name) values
  ('a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000008', 'Penny Preferred');
insert into public.shifts (organization_id, venue_id, staff_id, start_time, end_time, status) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000008', '2026-09-01 15:00:00+00', '2026-09-01 17:00:00+00', 'scheduled'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5100000-0000-0000-0000-000000000009', '2026-09-02 15:00:00+00', '2026-09-02 17:00:00+00', 'scheduled');

-- Incidents: two on the 14th, one at 22:30 local on the 15th (03:30Z on the 16th).
insert into public.incidents (organization_id, venue_id, title, description, severity, status, reported_by, created_at) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Fight at the bar', 'secret narrative', 'critical', 'open', 'a5100000-0000-0000-0000-000000000003', '2026-10-14 20:00:00+00'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Spill', 'secret narrative', 'low', 'resolved', 'a5100000-0000-0000-0000-000000000003', '2026-10-14 21:00:00+00'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Slip', 'secret narrative', 'high', 'investigating', 'a5100000-0000-0000-0000-000000000003', '2026-10-16 03:30:00+00');

-- Tasks due 14th (done), 15th (open, now overdue), 16th (cancelled).
insert into public.operational_tasks (organization_id, venue_id, title, status, due_at, completed_at) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Done task', 'completed', '2026-10-14 20:00:00+00', '2026-10-14 21:00:00+00'),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Late task', 'open', '2026-10-15 20:00:00+00', null),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Dropped task', 'cancelled', '2026-10-16 20:00:00+00', null);

-- Inventory: Vodka (2 of par 6), Gin (fine), Lime (inactive), Rum (two locations 1+1 of 3+3), and
-- another venue's low item.
insert into public.inventory_items (id, organization_id, venue_id, name, is_active, supplier, notes, unit_cost_usd) values
  ('a5400000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Vodka', true, 'Secret Supplier', 'secret note', 12.5),
  ('a5400000-0000-0000-0000-000000000002', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Gin', true, null, null, 10),
  ('a5400000-0000-0000-0000-000000000003', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Lime', false, null, null, 1),
  ('a5400000-0000-0000-0000-000000000004', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Rum', true, null, null, 9),
  ('a5400000-0000-0000-0000-000000000005', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a2', 'Elsewhere Whisky', true, null, null, 9);
insert into public.inventory_stock (organization_id, venue_id, inventory_item_id, area_id, quantity, par_level) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5400000-0000-0000-0000-000000000001', 'a5500000-0000-0000-0000-000000000001', 2, 6),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5400000-0000-0000-0000-000000000002', 'a5500000-0000-0000-0000-000000000001', 10, 6),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5400000-0000-0000-0000-000000000003', 'a5500000-0000-0000-0000-000000000001', 0, 5),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5400000-0000-0000-0000-000000000004', 'a5500000-0000-0000-0000-000000000001', 1, 3),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5400000-0000-0000-0000-000000000004', 'a5500000-0000-0000-0000-000000000002', 1, 3),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a2', 'a5400000-0000-0000-0000-000000000005', 'a5500000-0000-0000-0000-000000000001', 0, 9);

-- A completed count on the 15th (local) with three lines, and an unfinished one that is ignored.
insert into public.inventory_counts (id, organization_id, venue_id, count_type, status, completed_at, notes) values
  ('a5600000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'full', 'completed', '2026-10-16 03:00:00+00', 'secret'),
  ('a5600000-0000-0000-0000-000000000002', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'full', 'in_progress', null, null);
insert into public.inventory_count_items (organization_id, venue_id, count_id, stock_version, count_unit, location_name, item_name, previous_quantity, counted_quantity, unit_cost_snapshot) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5600000-0000-0000-0000-000000000001', 1, 'Each', 'Bar', 'Vodka', 3, 2, 12.50),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5600000-0000-0000-0000-000000000001', 1, 'Each', 'Bar', 'Gin', 1, 2, 4.00),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5600000-0000-0000-0000-000000000001', 1, 'Each', 'Bar', 'Rum', 5, 5, 9.00),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'a5600000-0000-0000-0000-000000000002', 1, 'Each', 'Bar', 'Rum', 10, 5, 9.00);

-- Private events: confirmed (food 1000.00 + beverage 500.00 - discount 100.00), a draft, a
-- cancelled one, a "sent" one at 23:30 local on 31 Oct (04:30Z on 1 Nov: still October in
-- Chicago) and a November one.
insert into public.crm_beos (id, organization_id, venue_id, event_name, event_date, status, guest_count, internal_notes) values
  ('a5700000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Wedding', '2026-10-20 23:00:00+00', 'confirmed', 80, 'secret'),
  ('a5700000-0000-0000-0000-000000000002', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Corporate', '2026-10-25 23:00:00+00', 'draft', 20, null),
  ('a5700000-0000-0000-0000-000000000003', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Cancelled party', '2026-10-22 23:00:00+00', 'cancelled', 10, null),
  ('a5700000-0000-0000-0000-000000000004', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'Late night', '2026-11-01 04:30:00+00', 'sent', 5, null),
  ('a5700000-0000-0000-0000-000000000005', 'a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'November', '2026-11-05 23:00:00+00', 'confirmed', 30, null);
insert into public.crm_beo_charges (beo_id, venue_id, description, category, amount_cents) values
  ('a5700000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-0000000000a1', 'Dinner', 'food', 100000),
  ('a5700000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-0000000000a1', 'Open bar', 'beverage', 50000),
  ('a5700000-0000-0000-0000-000000000001', 'a5300000-0000-0000-0000-0000000000a1', 'Loyalty', 'discount', 10000),
  ('a5700000-0000-0000-0000-000000000002', 'a5300000-0000-0000-0000-0000000000a1', 'Lunch', 'food', 20000),
  ('a5700000-0000-0000-0000-000000000003', 'a5300000-0000-0000-0000-0000000000a1', 'Cancelled', 'food', 5000);

-- POS: closed check at 23:30 local on the 17th (04:30Z on the 18th), one on the 18th, an open one.
insert into public.pos_checks (organization_id, venue_id, provider, external_check_id, opened_at, closed_at, status, guest_count, guest_name, server_name, subtotal_cents, tax_cents, tip_cents, total_cents) values
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'toast', 'c1', '2026-10-18 03:00:00+00', '2026-10-18 04:30:00+00', 'closed', 2, 'Secret Guest', 'Secret Server', 3800, 400, 800, 5000),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'toast', 'c2', '2026-10-18 23:00:00+00', '2026-10-19 00:00:00+00', 'closed', 4, null, null, 9000, 900, 1500, 11400),
  ('a5200000-0000-0000-0000-00000000000a', 'a5300000-0000-0000-0000-0000000000a1', 'toast', 'c3', '2026-10-18 23:30:00+00', null, 'open', 2, null, null, 100, 10, 0, 110);

set local session_replication_role = origin;

-- ---------------------------------------------------------------------------
-- Static checks: grants, pinned search_path, nothing returned that could leak.
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'ask_data\_%'),
  11::bigint,
  'the catalogue has eleven metric functions'
);
select is_empty(
  $$ select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'ask_data\_%'
       and (has_function_privilege('anon', p.oid, 'execute')
            or has_function_privilege('public', p.oid, 'execute')
            or not has_function_privilege('authenticated', p.oid, 'execute')) $$,
  'every metric is executable by authenticated only (not anon, not PUBLIC)'
);
select is_empty(
  $$ select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_hidden') and p.proname like 'ask\_data\_%' and p.prosecdef
       and not ('search_path=""' = any(coalesce(p.proconfig, '{}'))) $$,
  'every definer function of the catalogue pins an empty search_path'
);
select is_empty(
  $$ select p.proname, a from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       unnest(p.proargnames, p.proargmodes) as u(a, m)
     where n.nspname = 'public' and p.proname like 'ask_data\_%' and u.m = 't'
       and u.a ~* '(wage|salary|hourly|pay_?rate|phone|email|contact|note|allerg|diet|vip|special|request|description|narrative|deposit|payment|token|password|guest_name|address|title|supplier|cost|server|latitude|longitude)' $$,
  'no metric returns a forbidden column name (wages, contacts, notes, narratives, payments, ...)'
);
select is_empty(
  $$ select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       unnest(p.proallargtypes, p.proargmodes) as u(t, m)
     where n.nspname = 'public' and p.proname like 'ask_data\_%' and u.m = 't'
       and u.t in ('uuid'::regtype, 'jsonb'::regtype, 'json'::regtype, 'timestamptz'::regtype) $$,
  'no metric returns ids, raw json or raw timestamps'
);
select ok(
  not has_function_privilege('authenticated', 'app_hidden.ask_data_window(uuid, date, date)', 'execute')
  and not has_function_privilege('authenticated', 'app_hidden.ask_data_require_manager(uuid)', 'execute'),
  'the helper functions are not callable by clients'
);

-- ---------------------------------------------------------------------------
-- Authorisation: only managers of the venue (or org owner/admin) may call any metric.
-- ---------------------------------------------------------------------------
set local role authenticated;

-- Each call below is attempted as: staff, supervisor, manager of another venue, owner of another
-- org, and a signed-in user with no membership. All must be refused with 42501.
set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000003';
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17') $$, '42501', null, 'staff cannot run reservation_summary');
select throws_ok($$ select * from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31') $$, '42501', null, 'staff cannot run private_event_summary');
select throws_ok($$ select * from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run labour_hours');
select throws_ok($$ select * from public.ask_data_labour_overtime('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run labour_overtime');
select throws_ok($$ select * from public.ask_data_missed_clock_outs('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-25') $$, '42501', null, 'staff cannot run missed_clock_outs');
select throws_ok($$ select * from public.ask_data_shift_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run shift_hours');
select throws_ok($$ select * from public.ask_data_incident_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run incident_summary');
select throws_ok($$ select * from public.ask_data_low_stock('a5300000-0000-0000-0000-0000000000a1') $$, '42501', null, 'staff cannot run low_stock');
select throws_ok($$ select * from public.ask_data_inventory_variance('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run inventory_variance');
select throws_ok($$ select * from public.ask_data_task_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run task_summary');
select throws_ok($$ select * from public.ask_data_pos_sales_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'staff cannot run pos_sales_summary');

set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000002';
select throws_ok($$ select * from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'a supervisor cannot run labour_hours');
select throws_ok($$ select * from public.ask_data_pos_sales_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'a supervisor cannot run pos_sales_summary');

set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000005';
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17') $$, '42501', null, 'the manager of another venue cannot read venue A1 reservations');
select throws_ok($$ select * from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'the manager of another venue cannot read venue A1 hours');
select throws_ok($$ select * from public.ask_data_low_stock('a5300000-0000-0000-0000-0000000000a1') $$, '42501', null, 'the manager of another venue cannot read venue A1 stock');

set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000006';
select throws_ok($$ select * from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31') $$, '42501', null, 'an owner of another organization cannot read venue A1 events');

set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-0000000000ff';
select throws_ok($$ select * from public.ask_data_incident_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') $$, '42501', null, 'a user with no membership cannot read incidents');

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17') $$, '42501', null, 'a call with no signed-in user is refused');

-- ---------------------------------------------------------------------------
-- Manager: correct aggregates, venue-local day boundaries, one venue only.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000001';

-- Reservations on the venue-local 17th: r2 (00:30), r3, r4 - not r1 (23:30 on the 16th), not A2's.
select is(
  (select row(reservation_count, covers, served_covers, no_show_count, cancelled_count, no_show_rate_pct, cancel_rate_pct, total_buckets)::text
     from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17')),
  '(3,11,2,1,1,50.0,33.3,1)',
  'reservation totals for the venue-local 17th (midnight boundary, other venues excluded)'
);
select is(
  (select row(reservation_count, covers)::text
     from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17')),
  '(4,15)',
  'reservation totals over the 16th and 17th'
);
select is(
  (select string_agg(bucket || ':' || covers, ',' order by bucket)
     from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17', 'day')),
  '2026-10-16:4,2026-10-17:11',
  'reservations grouped by venue-local day'
);
select is(
  (select string_agg(bucket || ':' || reservation_count, ',' order by bucket)
     from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17', 'status')),
  'cancelled:1,completed:1,no_show:1,seated:1',
  'reservations grouped by status'
);
select is(
  (select row(reservation_count, covers, no_show_rate_pct)::text
     from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-12-01', '2026-12-02')),
  '(0,0,)',
  'a range with no reservations still answers with zeros (rate is null, not a guess)'
);

-- Parameter validation and caps.
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-04-04') $$, '22023', 'choose a date range of up to 93 days', 'a 94-day range is refused');
select lives_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-04-03') $$, 'a 93-day range is accepted');
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-16') $$, '22023', null, 'an inverted range is refused');
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', null, '2026-10-16') $$, '22023', null, 'a missing date is refused');
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17', 'guest_name') $$, '22023', 'unsupported group_by', 'an unknown group_by is refused');
select throws_ok($$ select * from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17', 'day; drop table reservations') $$, '22023', 'unsupported group_by', 'an injection-shaped group_by is refused');
select is(
  (select count(*) from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-03-31', 'day', 1000)),
  50::bigint,
  'a row limit above 50 is clamped to 50'
);
select is(
  (select max(total_buckets) from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-03-31', 'day', 1000)),
  60::bigint,
  'total_buckets reports the rows beyond the cap'
);
select is(
  (select count(*) from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-03-31', 'day', 0)),
  1::bigint,
  'a row limit below 1 is clamped to 1'
);
select is(
  (select min(bucket) from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-01-01', '2026-03-31', 'day', 3)),
  '2026-02-27',
  'capped day lists keep the most recent days'
);

-- Private events.
select is(
  (select string_agg(bucket || ':' || event_count || '/' || guest_count || '/' || charges_cents, ',' order by bucket)
     from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31')),
  'cancelled:1/10/5000,confirmed:1/80/140000,draft:1/20/20000,sent:1/5/0',
  'private events by status: charges net of discounts, November event excluded, 23:30 on 31 Oct still October'
);
select is(
  (select row(bucket, event_count, guest_count, charges_cents)::text
     from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31', 'month')),
  '(2026-10,3,105,160000)',
  'private events by month leave out cancelled events'
);
select is(
  (select row(event_count, charges_cents)::text
     from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31', 'month', 'cancelled')),
  '(1,5000)',
  'a status filter lets the cancelled events be asked for'
);
select throws_ok($$ select * from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31', 'month', 'x or 1=1') $$, '22023', 'unsupported status', 'an unknown status filter is refused');

-- Labour.
select is(
  (select string_agg(bucket || ':' || worked_hours || '/' || punch_count || '/' || open_punch_count, ',' order by worked_hours desc)
     from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18')),
  'Tess Tester:42.50/5/0,Tom Two:6.00/1/0',
  'hours per person: unpaid breaks removed, paid breaks kept, only this venue''s people'
);
select is(
  (select bucket from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18', 'person', 1)),
  'Tess Tester',
  'who worked the most hours comes first'
);
select is(
  (select row(bucket, worked_hours, punch_count)::text
     from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18', 'day')
    where bucket = '2026-10-13'),
  '(2026-10-13,14.50,2)',
  'hours by day: a punch that starts at 22:00 local belongs to that venue-local day (03:00Z the next day)'
);
select is(
  (select row(worked_hours, punch_count, open_punch_count, total_buckets)::text
     from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18', 'total')),
  '(48.50,6,0,1)',
  'total hours for the week'
);
select is(
  (select count(*) from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18', 'person')
    where bucket = 'Mia Elsewhere'),
  0::bigint,
  'the manager of another venue never appears in this venue''s hours'
);
select is(
  (select row(bucket, week_start, worked_hours, overtime_hours)::text
     from public.ask_data_labour_overtime('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-14')),
  '("Tess Tester",2026-10-12,42.50,2.50)',
  'overtime is judged over the whole Monday-Sunday week even for a one-day range'
);
select is(
  (select count(*) from public.ask_data_labour_overtime('a5300000-0000-0000-0000-0000000000a1', '2026-10-19', '2026-10-25')),
  0::bigint,
  'a week under 40 hours has no overtime'
);
select is(
  (select row(bucket, clock_in_date)::text
     from public.ask_data_missed_clock_outs('a5300000-0000-0000-0000-0000000000a1', '2026-10-20', '2026-10-20')),
  '("Tom Two",2026-10-20)',
  'a punch left open for more than 16 hours is a missed clock-out'
);
select is(
  (select count(*) from public.ask_data_missed_clock_outs('a5300000-0000-0000-0000-0000000000a1',
                          ((now() at time zone 'America/Chicago')::date - 1), ((now() at time zone 'America/Chicago')::date + 1))),
  0::bigint,
  'a punch open for two hours is not a missed clock-out'
);

-- Shifts.
select is(
  (select string_agg(bucket || ':' || scheduled_hours || '/' || shift_count || '/' || open_shift_count, ',' order by scheduled_hours desc)
     from public.ask_data_shift_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16')),
  'Tess Tester:10.00/2/0,Tom Two:8.00/1/0,Open (unassigned):4.00/1/1',
  'scheduled hours per person, cancelled shifts excluded, open shifts reported'
);
select is(
  (select row(scheduled_hours, shift_count, open_shift_count)::text
     from public.ask_data_shift_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16', 'total')),
  '(22.00,4,1)',
  'total scheduled hours'
);

select is(
  (select string_agg(bucket, ',' order by bucket)
     from public.ask_data_shift_hours('a5300000-0000-0000-0000-0000000000a1', '2026-09-01', '2026-09-02')),
  'Penny Preferred,Unnamed team member',
  'names: manager-entered preferred name wins, and nobody falls back to an email address'
);
select is(
  (select count(*) from public.ask_data_shift_hours('a5300000-0000-0000-0000-0000000000a1', '2026-09-01', '2026-09-02') where bucket like '%@%'),
  0::bigint,
  'names: no email address ever appears as a bucket'
);

-- Incidents (counts only).
select is(
  (select string_agg(bucket || ':' || incident_count || '/' || unresolved_count, ',' order by bucket)
     from public.ask_data_incident_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16')),
  'critical:1/1,high:1/1,low:1/0',
  'incidents by severity'
);
select is(
  (select string_agg(bucket || ':' || incident_count, ',' order by bucket)
     from public.ask_data_incident_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16', 'day')),
  '2026-10-14:2,2026-10-15:1',
  'incidents by venue-local day (22:30 on the 15th stays on the 15th)'
);

-- Tasks.
select is(
  (select row(tasks_due, completed_count, overdue_count, still_open_count, completed_in_range)::text
     from public.ask_data_task_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16')),
  '(2,1,1,0,1)',
  'task counts: cancelled tasks excluded, past-due open tasks are overdue'
);

-- Inventory.
select is(
  (select string_agg(bucket || ':' || quantity || '/' || par_level || '/' || shortfall, ',' order by shortfall desc, bucket)
     from public.ask_data_low_stock('a5300000-0000-0000-0000-0000000000a1')),
  'Rum:2.0000/6.0000/4.0000,Vodka:2.0000/6.0000/4.0000',
  'low stock lists active items below par (summed over locations); fine, inactive and other-venue items are excluded'
);
select is(
  (select max(total_buckets) from public.ask_data_low_stock('a5300000-0000-0000-0000-0000000000a1', 1)),
  2::bigint,
  'low stock reports how many items are below par even when capped'
);
select is(
  (select row(count_sessions, items_counted, items_with_variance, net_variance_value, shortfall_value)::text
     from public.ask_data_inventory_variance('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18')),
  '(1,3,2,-8.50,12.50)',
  'count variance totals use completed counts only'
);
select is(
  (select bucket from public.ask_data_inventory_variance('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18', 'day')),
  '2026-10-15',
  'count variance by venue-local day'
);

-- POS.
select is(
  (select row(check_count, covers, subtotal_cents, tax_cents, tip_cents, total_cents)::text
     from public.ask_data_pos_sales_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17')),
  '(1,2,3800,400,800,5000)',
  'POS totals for the venue-local 17th (a check closed at 23:30 local) exclude open checks'
);
select is(
  (select string_agg(bucket || ':' || total_cents, ',' order by bucket)
     from public.ask_data_pos_sales_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-19', 'day')),
  '2026-10-17:5000,2026-10-18:11400',
  'POS totals by day'
);

-- Nothing the metrics return contains the seeded private text.
select is(
  (select count(*) from (
      select to_jsonb(r)::text as j from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-16', '2026-10-17', 'status') r
      union all select to_jsonb(r)::text from public.ask_data_incident_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-14', '2026-10-16') r
      union all select to_jsonb(r)::text from public.ask_data_low_stock('a5300000-0000-0000-0000-0000000000a1') r
      union all select to_jsonb(r)::text from public.ask_data_private_event_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-01', '2026-10-31') r
      union all select to_jsonb(r)::text from public.ask_data_pos_sales_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-19', 'day') r
      union all select to_jsonb(r)::text from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a1', '2026-10-12', '2026-10-18') r
    ) x
    where j ~* '(secret|555-01|@example|allerg|vip|nuts)'),
  0::bigint,
  'seeded notes, narratives, contact details, supplier and server names never appear in results'
);

-- ---------------------------------------------------------------------------
-- Org owner (membership with no venue) is allowed; another venue's data stays separate.
-- ---------------------------------------------------------------------------
set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000007';
select is(
  (select reservation_count from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a1', '2026-10-17', '2026-10-17')),
  3::bigint,
  'an organization owner can run metrics for a venue of their organization'
);
select is(
  (select covers from public.ask_data_reservation_summary('a5300000-0000-0000-0000-0000000000a2', '2026-10-17', '2026-10-17')),
  50::bigint,
  'the same owner gets venue A2 its own numbers (UTC day), not A1''s'
);

-- Venue A2's manager sees A2 data only.
set local "request.jwt.claim.sub" to 'a5100000-0000-0000-0000-000000000005';
select is(
  (select string_agg(bucket, ',') from public.ask_data_labour_hours('a5300000-0000-0000-0000-0000000000a2', '2026-10-12', '2026-10-18')),
  'Mia Elsewhere',
  'the A2 manager sees A2 hours, with only A2 people'
);

reset role;
select * from finish();
rollback;
