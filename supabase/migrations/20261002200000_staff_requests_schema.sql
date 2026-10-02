-- Phase 4 feature: staff requests (time off, shift pickup, shift drop, availability, etc.).
-- venue-scoped, RLS = member can create/view own, manager can view all in venue and review.
-- organization_id is derived from venue_id via trigger (derive, don't trust).
-- Column-restricted updates (requester can only cancel; manager reviews) enforced via trigger.

create table public.staff_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (
    kind in (
      'add_shift',
      'drop_shift',
      'time_off',
      'shift_swap',
      'open_shift',
      'sick_leave',
      'time_correction',
      'other'
    )
  ),
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied', 'cancelled')),
  title text not null check (char_length(trim(title)) > 0),
  details text not null default '',
  requested_for_date date,
  requested_range_start date,
  requested_range_end date,
  constraint staff_requests_range_check check (
    requested_range_end is null
    or requested_range_start is null
    or requested_range_end >= requested_range_start
  ),
  requested_shift_id uuid references public.shifts (id) on delete set null,
  availability jsonb,
  reviewer_id uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  response_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index staff_requests_venue_id_idx on public.staff_requests (venue_id);
create index staff_requests_organization_id_idx on public.staff_requests (organization_id);
create index staff_requests_user_id_idx on public.staff_requests (user_id);
create index staff_requests_status_idx on public.staff_requests (status);
create index staff_requests_requested_shift_id_idx on public.staff_requests (requested_shift_id);
create index staff_requests_reviewer_id_idx on public.staff_requests (reviewer_id);

create or replace function app_hidden.prepare_staff_request_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_shift_venue_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;

  if new.requested_shift_id is not null then
    select venue_id into v_shift_venue_id from public.shifts where id = new.requested_shift_id;
    if v_shift_venue_id is null or v_shift_venue_id <> new.venue_id then
      raise exception 'shift % does not belong to venue %', new.requested_shift_id, new.venue_id;
    end if;
  end if;

  new.organization_id := v_org_id;
  new.user_id := auth.uid();
  new.status := 'pending';
  new.reviewer_id := null;
  new.reviewed_at := null;
  new.response_notes := null;
  return new;
end;
$$;

create trigger prepare_staff_request_insert
  before insert on public.staff_requests
  for each row execute function app_hidden.prepare_staff_request_insert();

create or replace function app_hidden.enforce_staff_request_update()
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
    if old.status <> 'pending' then
      raise exception 'only pending requests can be reviewed' using errcode = '42501';
    end if;

    if new.status not in ('approved', 'denied', 'cancelled') then
      raise exception 'manager must set status to approved, denied, or cancelled' using errcode = '42501';
    end if;

    new.reviewer_id := auth.uid();
    new.reviewed_at := now();

    if new.organization_id is distinct from old.organization_id
      or new.venue_id is distinct from old.venue_id
      or new.user_id is distinct from old.user_id
      or new.kind is distinct from old.kind
      or new.title is distinct from old.title
      or new.details is distinct from old.details
      or new.requested_for_date is distinct from old.requested_for_date
      or new.requested_range_start is distinct from old.requested_range_start
      or new.requested_range_end is distinct from old.requested_range_end
      or new.requested_shift_id is distinct from old.requested_shift_id
      or new.availability is distinct from old.availability
      or new.created_at is distinct from old.created_at
    then
      raise exception 'only status, reviewer fields, and response_notes may be updated by a manager' using errcode = '42501';
    end if;

    return new;
  end if;

  if auth.uid() = old.user_id then
    if old.status <> 'pending' then
      raise exception 'this request is no longer pending' using errcode = '42501';
    end if;

    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own request' using errcode = '42501';
    end if;

    if new.organization_id is distinct from old.organization_id
      or new.venue_id is distinct from old.venue_id
      or new.user_id is distinct from old.user_id
      or new.kind is distinct from old.kind
      or new.title is distinct from old.title
      or new.details is distinct from old.details
      or new.requested_for_date is distinct from old.requested_for_date
      or new.requested_range_start is distinct from old.requested_range_start
      or new.requested_range_end is distinct from old.requested_range_end
      or new.requested_shift_id is distinct from old.requested_shift_id
      or new.availability is distinct from old.availability
      or new.reviewer_id is distinct from old.reviewer_id
      or new.reviewed_at is distinct from old.reviewed_at
      or new.response_notes is distinct from old.response_notes
      or new.created_at is distinct from old.created_at
    then
      raise exception 'the requester may only cancel the request' using errcode = '42501';
    end if;

    return new;
  end if;

  raise exception 'not authorized to update this staff request' using errcode = '42501';
end;
$$;

create trigger enforce_staff_request_update
  before update on public.staff_requests
  for each row execute function app_hidden.enforce_staff_request_update();

create or replace function app_hidden.sync_staff_request_timestamp()
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

create trigger sync_staff_request_timestamp
  before update on public.staff_requests
  for each row execute function app_hidden.sync_staff_request_timestamp();

create or replace function app_hidden.apply_approved_staff_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    if new.kind in ('drop_shift', 'open_shift') and new.requested_shift_id is not null then
      update public.shifts
      set staff_id = null
      where id = new.requested_shift_id and venue_id = new.venue_id and staff_id = new.user_id;
    elsif new.kind = 'add_shift' and new.requested_shift_id is not null then
      update public.shifts
      set staff_id = new.user_id, status = 'scheduled'
      where id = new.requested_shift_id and venue_id = new.venue_id and staff_id is null;
    end if;
  end if;
  return new;
end;
$$;

create trigger apply_approved_staff_request
  after update on public.staff_requests
  for each row execute function app_hidden.apply_approved_staff_request();

alter table public.staff_requests enable row level security;
alter table public.staff_requests force row level security;

create policy staff_requests_select on public.staff_requests
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or (
      app_hidden.is_venue_member(venue_id)
      and user_id = auth.uid()
    )
  );

create policy staff_requests_insert on public.staff_requests
  for insert to authenticated
  with check (app_hidden.is_venue_member(venue_id));

create policy staff_requests_update on public.staff_requests
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or (
      app_hidden.is_venue_member(venue_id)
      and user_id = auth.uid()
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or (
      app_hidden.is_venue_member(venue_id)
      and user_id = auth.uid()
    )
  );
