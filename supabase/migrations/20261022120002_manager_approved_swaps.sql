-- Launch review U1: swaps must say which shift they are, must not double-book anyone, and must
-- be approved by a manager (as the FAQ promises) rather than "accepted" by whoever taps first.
--
-- New flow:
--   pending  -> a teammate taps "Take shift" (public.claim_shift_swap)          -> claimed
--   claimed  -> a manager approves on the taker's behalf (approve_shift_swap)    -> accepted
--   pending  -> a manager approves a swap offered to one named person            -> accepted
--   pending/claimed -> the requester cancels, or a manager declines            -> cancelled/declined
-- A manager taking a shift themselves (claim as a manager) is applied at once, since they are
-- the approver. Approval never puts the approving manager on the shift.
--
-- Only these functions may move a swap to claimed/accepted or set who takes it; direct table
-- updates are limited to cancel (requester) and decline/cancel (manager). Assigning a shift
-- through a swap or an approved pick-up request is refused when it overlaps another shift of
-- the same person, unless the caller explicitly passes p_allow_overlap.

alter table public.shift_swaps drop constraint shift_swaps_status_check;
alter table public.shift_swaps add constraint shift_swaps_status_check
  check (status in ('pending', 'claimed', 'accepted', 'declined', 'cancelled'));

alter table public.shift_swaps
  add column claimed_at timestamptz,
  add column approved_by uuid references auth.users (id) on delete set null,
  add column approved_at timestamptz;

create index shift_swaps_approved_by_idx on public.shift_swaps (approved_by);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- "Server · Thu Oct 22, 04:30 PM" in the shift's venue time.
create or replace function app_hidden.describe_shift(p_shift_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(nullif(s.role_label, '') || ' · ', '') ||
    to_char(
      s.start_time at time zone case
        when exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v.timezone)
          then v.timezone else 'UTC' end,
      'Dy Mon DD, HH12:MI AM'
    )
  from public.shifts s
  join public.venues v on v.id = s.venue_id
  where s.id = p_shift_id;
$$;

-- The first other live shift of p_user that overlaps p_shift_id, described, or null.
create or replace function app_hidden.shift_overlap_for(p_user uuid, p_shift_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select app_hidden.describe_shift(o.id)
  from public.shifts s
  join public.shifts o
    on o.staff_id = p_user and o.id <> s.id and o.status <> 'cancelled'
   and o.start_time < s.end_time and o.end_time > s.start_time
  where s.id = p_shift_id
  order by o.start_time, o.id
  limit 1;
$$;

create or replace function app_hidden.assert_no_shift_overlap(p_user uuid, p_shift_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_clash text;
begin
  if coalesce(current_setting('app.allow_shift_overlap', true), '') = 'on' then
    return;
  end if;
  v_clash := app_hidden.shift_overlap_for(p_user, p_shift_id);
  if v_clash is not null then
    raise exception 'shift_overlap: already working %', v_clash
      using errcode = '23P01';
  end if;
end;
$$;

create or replace function app_hidden.display_name_for(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select nullif(trim(p.display_name), '') from public.profiles p where p.id = p_user),
    'A teammate'
  );
$$;

revoke all on function app_hidden.describe_shift(uuid) from public, anon, authenticated;
revoke all on function app_hidden.shift_overlap_for(uuid, uuid) from public, anon, authenticated;
revoke all on function app_hidden.assert_no_shift_overlap(uuid, uuid) from public, anon, authenticated;
revoke all on function app_hidden.display_name_for(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Inserts start clean; a claimed swap still blocks a second request
-- ---------------------------------------------------------------------------

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
  new.claimed_at := null;
  new.approved_by := null;
  new.approved_at := null;
  return new;
end;
$$;

create or replace function app_hidden.guard_duplicate_pending_swap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() is distinct from
     (select staff_id from public.shifts where id = new.shift_id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('swap:' || new.shift_id::text, 0));
  if exists (select 1 from public.shift_swaps
    where shift_id = new.shift_id and status in ('pending', 'claimed')) then
    raise exception 'a pending swap already exists for this shift'
      using errcode = '23505';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Direct updates: cancel and decline only
-- ---------------------------------------------------------------------------

create or replace function app_hidden.enforce_shift_swap_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Account deletion clears this account from rows it touched (see account_deletion_fixes).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;
  -- claim_shift_swap / approve_shift_swap validated this transition themselves.
  if coalesce(current_setting('app.shift_swap_transition', true), '') = 'on' then
    return new;
  end if;
  -- ON DELETE SET NULL from a deleted auth user (no client session, status untouched).
  if auth.uid() is null and new.status = old.status then
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.accepted_by is distinct from old.accepted_by
    or new.claimed_at is distinct from old.claimed_at
    or new.approved_by is distinct from old.approved_by
    or new.approved_at is distinct from old.approved_at
    or new.created_at is distinct from old.created_at
  then
    raise exception 'take or approve a swap with its Take/Approve action'
      using errcode = '42501';
  end if;

  if old.status not in ('pending', 'claimed') then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    if new.status in ('declined', 'cancelled') then
      return new;
    end if;
    raise exception 'approve a swap with approve_shift_swap' using errcode = '42501';
  end if;

  if auth.uid() = old.requested_by then
    if new.status = 'cancelled' then
      return new;
    end if;
    raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
  end if;

  raise exception 'take an open swap with claim_shift_swap' using errcode = '42501';
end;
$$;

-- Reassignment on approval, refusing a double-booking unless the approver overrode it.
create or replace function app_hidden.apply_accepted_shift_swap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    perform app_hidden.assert_no_shift_overlap(new.accepted_by, old.shift_id);
    update public.shifts set staff_id = new.accepted_by
      where id = old.shift_id and venue_id = old.venue_id
        and staff_id = old.requested_by;
    if not found then
      raise exception 'shift assignment changed; request a new swap'
        using errcode = '40001';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- A teammate offers to take an open swap (or one offered to them). Staff wait for a manager;
-- a manager taking it themselves is applied at once. Returns the resulting status.
create or replace function public.claim_shift_swap(
  p_swap_id uuid,
  p_allow_overlap boolean default false
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_swap public.shift_swaps%rowtype;
  v_shift public.shifts%rowtype;
  v_status text;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select * into v_swap from public.shift_swaps where id = p_swap_id for update;
  if not found or not app_hidden.is_venue_member(v_swap.venue_id) then
    raise exception 'swap request not found' using errcode = '42501';
  end if;
  if v_swap.status <> 'pending' then
    raise exception 'this swap is no longer open' using errcode = '40001';
  end if;
  if v_swap.requested_by = v_uid then
    raise exception 'you cannot take your own shift' using errcode = '42501';
  end if;
  if v_swap.offered_to is not null and v_swap.offered_to <> v_uid then
    raise exception 'this swap request was offered to someone else' using errcode = '42501';
  end if;
  select * into v_shift from public.shifts where id = v_swap.shift_id for update;
  if v_shift.staff_id is distinct from v_swap.requested_by or v_shift.status <> 'scheduled' then
    raise exception 'shift assignment changed; request a new swap' using errcode = '40001';
  end if;

  perform set_config('app.allow_shift_overlap', case when p_allow_overlap then 'on' else '' end, true);
  perform app_hidden.assert_no_shift_overlap(v_uid, v_shift.id);

  perform set_config('app.shift_swap_transition', 'on', true);
  if app_hidden.has_venue_role(
    v_swap.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    update public.shift_swaps
      set status = 'accepted', accepted_by = v_uid, claimed_at = now(),
          approved_by = v_uid, approved_at = now()
      where id = p_swap_id;
    v_status := 'accepted';
  else
    update public.shift_swaps
      set status = 'claimed', accepted_by = v_uid, claimed_at = now()
      where id = p_swap_id;
    v_status := 'claimed';
  end if;
  perform set_config('app.shift_swap_transition', '', true);
  perform set_config('app.allow_shift_overlap', '', true);
  return v_status;
end;
$$;

-- A manager approves a swap on behalf of whoever is taking it: the teammate who claimed it, or
-- the one person it was offered to. The approver is recorded, never assigned.
create or replace function public.approve_shift_swap(
  p_swap_id uuid,
  p_allow_overlap boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_swap public.shift_swaps%rowtype;
  v_taker uuid;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select * into v_swap from public.shift_swaps where id = p_swap_id for update;
  if not found or not app_hidden.has_venue_role(
    v_swap.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'only a manager can approve swaps' using errcode = '42501';
  end if;
  if v_swap.status = 'claimed' then
    v_taker := v_swap.accepted_by;
  elsif v_swap.status = 'pending' and v_swap.offered_to is not null then
    v_taker := v_swap.offered_to;
  elsif v_swap.status = 'pending' then
    raise exception 'no teammate has offered to take this shift yet' using errcode = '22023';
  else
    raise exception 'this swap is no longer pending' using errcode = '40001';
  end if;
  if v_taker is null then
    raise exception 'no teammate has offered to take this shift yet' using errcode = '22023';
  end if;

  perform set_config('app.allow_shift_overlap', case when p_allow_overlap then 'on' else '' end, true);
  perform set_config('app.shift_swap_transition', 'on', true);
  update public.shift_swaps
    set status = 'accepted', accepted_by = v_taker,
        claimed_at = coalesce(claimed_at, now()),
        approved_by = v_uid, approved_at = now()
    where id = p_swap_id;
  perform set_config('app.shift_swap_transition', '', true);
  perform set_config('app.allow_shift_overlap', '', true);
end;
$$;

revoke all on function public.claim_shift_swap(uuid, boolean) from public, anon;
grant execute on function public.claim_shift_swap(uuid, boolean) to authenticated;
revoke all on function public.approve_shift_swap(uuid, boolean) from public, anon;
grant execute on function public.approve_shift_swap(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Tell the people involved
-- ---------------------------------------------------------------------------

create or replace function app_hidden.notify_shift_swap_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift text := coalesce(app_hidden.describe_shift(new.shift_id), 'a shift');
  v_requester text := app_hidden.display_name_for(new.requested_by);
  v_taker text;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;
  if new.accepted_by is not null then
    v_taker := app_hidden.display_name_for(new.accepted_by);
  end if;

  if new.status = 'claimed' then
    insert into public.notification_events (
      organization_id, venue_id, target_user_id, audience, kind, title, body, data
    ) values (
      new.organization_id, new.venue_id, null, 'venue_managers', 'shift_swap',
      'Shift swap needs approval',
      v_taker || ' wants to take ' || v_requester || '''s ' || v_shift,
      jsonb_build_object('origin', 'db', 'shift_swap_id', new.id, 'shift_id', new.shift_id)
    ), (
      new.organization_id, new.venue_id, new.requested_by, 'user', 'shift_swap',
      'Someone will take your shift',
      v_taker || ' offered to take your ' || v_shift || '. A manager still needs to approve it.',
      jsonb_build_object('origin', 'db', 'shift_swap_id', new.id, 'shift_id', new.shift_id)
    );
  elsif new.status = 'accepted' then
    insert into public.notification_events (
      organization_id, venue_id, target_user_id, audience, kind, title, body, data
    ) values (
      new.organization_id, new.venue_id, new.requested_by, 'user', 'shift_swap',
      'Shift swap approved',
      'Your ' || v_shift || ' is now ' || coalesce(v_taker, 'a teammate') || '''s.',
      jsonb_build_object('origin', 'db', 'shift_swap_id', new.id, 'shift_id', new.shift_id)
    );
  elsif new.status = 'declined' then
    insert into public.notification_events (
      organization_id, venue_id, target_user_id, audience, kind, title, body, data
    )
    select new.organization_id, new.venue_id, u, 'user', 'shift_swap',
      'Shift swap declined',
      'The swap for ' || v_requester || '''s ' || v_shift || ' was declined. The shift stays with '
        || v_requester || '.',
      jsonb_build_object('origin', 'db', 'shift_swap_id', new.id, 'shift_id', new.shift_id)
    from unnest(array[new.requested_by, new.accepted_by]) as t(u)
    where u is not null;
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.notify_shift_swap_transition() from public, anon, authenticated;

create trigger trg_shift_swaps_notify_transition
  after update of status on public.shift_swaps
  for each row execute function app_hidden.notify_shift_swap_transition();
