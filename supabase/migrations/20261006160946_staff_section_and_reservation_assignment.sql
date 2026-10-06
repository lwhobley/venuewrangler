-- Section a person works on a shift (matches floor_tables.section), set by managers when
-- scheduling. Shift writes are already manager-only by RLS.
alter table public.shifts add column if not exists section text;

-- The team member a reservation is assigned to (its server/host). Any venue member can
-- already update reservations, so no policy change is needed.
alter table public.reservations
  add column if not exists assigned_to uuid references auth.users (id) on delete set null;

create index if not exists reservations_assigned_to_idx
  on public.reservations (venue_id, assigned_to, reservation_time);
