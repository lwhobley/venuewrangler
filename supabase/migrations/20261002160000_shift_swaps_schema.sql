-- Phase 3 feature: shift swaps, on top of supabase/migrations/20261002120000_schedules_schema.
-- organization_id/venue_id are derived from shift_id (not supplied directly, unlike most
-- other tables, since shift_id is the natural client-supplied FK here) via trigger, same
-- "derive, don't trust" discipline as everywhere else.
create table public.shift_swaps (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  shift_id uuid not null references public.shifts (id) on delete cascade,
  requested_by uuid not null references auth.users (id),
  offered_to uuid references auth.users (id),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  accepted_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index shift_swaps_venue_id_idx on public.shift_swaps (venue_id);
create index shift_swaps_shift_id_idx on public.shift_swaps (shift_id);
create index shift_swaps_requested_by_idx on public.shift_swaps (requested_by);

create or replace function app_hidden.prepare_shift_swap_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_venue_id uuid;
begin
  select organization_id, venue_id into v_org_id, v_venue_id
  from public.shifts where id = new.shift_id;
  if v_venue_id is null then
    raise exception 'shift % does not exist', new.shift_id;
  end if;
  new.organization_id := v_org_id;
  new.venue_id := v_venue_id;
  new.requested_by := auth.uid();
  new.status := 'pending';
  new.accepted_by := null;
  return new;
end;
$$;

create trigger prepare_shift_swap_insert
  before insert on public.shift_swaps
  for each row execute function app_hidden.prepare_shift_swap_insert();

-- RLS (below) only decides WHICH ROW a client may touch at all (any venue member, since both
-- the requester cancelling and another staff member accepting are "a venue member touching a
-- venue-visible row"). This trigger narrows WHAT a given caller may actually change about it:
-- the original requester may only cancel their own still-pending request; anyone else (who
-- isn't a manager) may only accept a still-open or specifically-offered-to-them pending
-- request, and only by setting status to accepted and accepted_by to themselves. A manager
-- tier may do either transition freely (e.g. declining on a no-show's behalf).
create or replace function app_hidden.enforce_shift_swap_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.status <> 'pending' then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if auth.uid() = old.requested_by then
    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
    end if;
  else
    if new.status <> 'accepted' or new.accepted_by is distinct from auth.uid() then
      raise exception 'you may only accept this swap request as yourself' using errcode = '42501';
    end if;
    if old.offered_to is not null and old.offered_to <> auth.uid() then
      raise exception 'this swap request was offered to someone else' using errcode = '42501';
    end if;
  end if;

  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.created_at is distinct from old.created_at
  then
    raise exception 'only a swap request''s status and accepted_by may change' using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger enforce_shift_swap_update
  before update on public.shift_swaps
  for each row execute function app_hidden.enforce_shift_swap_update();

create or replace function app_hidden.sync_shift_swap_timestamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Runs after enforce_shift_swap_update in trigger-name alphabetical order within the same
-- timing/event, which is fine here since it only touches updated_at.
create trigger sync_shift_swap_timestamp
  before update on public.shift_swaps
  for each row execute function app_hidden.sync_shift_swap_timestamp();

-- The actual reassignment: once a swap is accepted, the underlying shift's staff_id moves to
-- whoever accepted it. A separate AFTER trigger (not folded into enforce_shift_swap_update)
-- because it writes to a different table and should only fire once the status change has
-- actually been committed to this row.
create or replace function app_hidden.apply_accepted_shift_swap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    update public.shifts set staff_id = new.accepted_by where id = new.shift_id;
  end if;
  return new;
end;
$$;

create trigger apply_accepted_shift_swap
  after update on public.shift_swaps
  for each row execute function app_hidden.apply_accepted_shift_swap();

alter table public.shift_swaps enable row level security;
alter table public.shift_swaps force row level security;

create policy shift_swaps_select_venue_members on public.shift_swaps
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

-- A venue member may only request a swap for a shift they are themselves currently assigned
-- to — the trigger above already forces requested_by to auth.uid(), so this just checks the
-- shift's current staff_id matches too.
create policy shift_swaps_insert_own_shift on public.shift_swaps
  for insert to authenticated
  with check (
    app_hidden.is_venue_member(venue_id)
    and exists (
      select 1 from public.shifts s
      where s.id = shift_id and s.staff_id = auth.uid()
    )
  );

create policy shift_swaps_update_venue_members on public.shift_swaps
  for update to authenticated
  using (app_hidden.is_venue_member(venue_id))
  with check (app_hidden.is_venue_member(venue_id));
