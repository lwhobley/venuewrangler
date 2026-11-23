-- H4 / M20 follow-ups for attested time clock (after privilege_gate):
--   * Single record_attested_punch overload with optional p_shift_id that opens
--     app_hidden.privilege_gate('attested_punch') — not the old app.* GUC.
--   * start_time_entry_break / end_time_entry_break append or close breaks
--     server-side so the client does not read-modify-write the breaks JSON.
--
-- Must run after 20261123150002_privilege_gate_invite_guest_swap.sql. The earlier
-- draft of this change (20261024…) created a 9-arg overload that co-existed with
-- the privilege_gate 8-arg function and made call sites ambiguous (42725).

-- -----------------------------------------------------------------------------
-- record_attested_punch: one overload, privilege gate + optional shift_id
-- -----------------------------------------------------------------------------
drop function if exists public.record_attested_punch(
  uuid, uuid, text, double precision, double precision, double precision, boolean, boolean
);
drop function if exists public.record_attested_punch(
  uuid, uuid, text, double precision, double precision, double precision, boolean, boolean, uuid
);

create or replace function public.record_attested_punch(
  p_user_id uuid,
  p_venue_id uuid,
  p_kind text,
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision,
  p_mocked boolean,
  p_attested boolean,
  p_shift_id uuid default null
)
returns public.time_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_entry public.time_entries;
begin
  if p_kind not in ('in', 'out') then
    raise exception 'invalid punch kind' using errcode = '22023';
  end if;

  select v.organization_id into v_org from public.venues v where v.id = p_venue_id;
  if v_org is null or not exists (
    select 1 from public.memberships m
    where m.user_id = p_user_id and m.organization_id = v_org
      and (m.venue_id = p_venue_id or m.venue_id is null)
  ) then
    raise exception 'not a member of this venue' using errcode = '42501';
  end if;

  -- Identity impersonation for triggers (not an authz bypass).
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  if coalesce(p_attested, false) then
    perform app_hidden.open_privilege_gate('attested_punch');
  end if;

  if p_kind = 'in' then
    insert into public.time_entries (
      venue_id, shift_id, clock_in_lat, clock_in_lng, clock_in_accuracy_m, clock_in_mocked
    )
    values (
      p_venue_id, p_shift_id, p_lat, p_lng, p_accuracy_m, coalesce(p_mocked, false)
    )
    returning * into v_entry;
  else
    update public.time_entries
       set is_open = false,
           clock_out_lat = p_lat, clock_out_lng = p_lng, clock_out_accuracy_m = p_accuracy_m,
           clock_out_mocked = coalesce(p_mocked, false)
     where user_id = p_user_id and venue_id = p_venue_id and is_open
    returning * into v_entry;
    if v_entry.id is null then
      perform app_hidden.close_privilege_gate('attested_punch');
      raise exception 'no open punch to close' using errcode = 'P0002';
    end if;
  end if;

  perform app_hidden.close_privilege_gate('attested_punch');
  return v_entry;
end;
$$;

revoke all on function public.record_attested_punch(
  uuid, uuid, text, double precision, double precision, double precision, boolean, boolean, uuid
) from public, anon, authenticated;
grant execute on function public.record_attested_punch(
  uuid, uuid, text, double precision, double precision, double precision, boolean, boolean, uuid
) to service_role;

-- -----------------------------------------------------------------------------
-- Break RPCs: server-side append / close (SECURITY INVOKER so RLS + triggers apply)
-- -----------------------------------------------------------------------------
create or replace function public.start_time_entry_break(
  p_entry_id uuid,
  p_type text
)
returns public.time_entries
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_breaks jsonb;
begin
  if p_type is null or p_type not in ('paid', 'unpaid') then
    raise exception 'invalid break type' using errcode = '22023';
  end if;

  select * into v_entry
  from public.time_entries
  where id = p_entry_id
  for update;

  if v_entry.id is null then
    raise exception 'time entry not found' using errcode = 'P0002';
  end if;
  if not v_entry.is_open then
    raise exception 'cannot start a break on a closed entry' using errcode = '42501';
  end if;
  if v_entry.user_id is distinct from auth.uid() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_breaks := coalesce(v_entry.breaks, '[]'::jsonb);

  update public.time_entries
     set breaks = v_breaks || jsonb_build_array(
       jsonb_build_object(
         'type', p_type,
         'start_at', now(),
         'end_at', null
       )
     )
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end;
$$;

create or replace function public.end_time_entry_break(
  p_entry_id uuid
)
returns public.time_entries
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_breaks jsonb;
  v_len int;
  v_last jsonb;
begin
  select * into v_entry
  from public.time_entries
  where id = p_entry_id
  for update;

  if v_entry.id is null then
    raise exception 'time entry not found' using errcode = 'P0002';
  end if;
  if not v_entry.is_open then
    raise exception 'cannot end a break on a closed entry' using errcode = '42501';
  end if;
  if v_entry.user_id is distinct from auth.uid() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_breaks := coalesce(v_entry.breaks, '[]'::jsonb);
  v_len := jsonb_array_length(v_breaks);
  if v_len = 0 then
    raise exception 'no open break to end' using errcode = 'P0002';
  end if;

  v_last := v_breaks -> (v_len - 1);
  if (v_last ->> 'end_at') is not null then
    raise exception 'no open break to end' using errcode = 'P0002';
  end if;

  -- Trigger forces end_at to now(); any non-null value signals "close the open break".
  update public.time_entries
     set breaks = jsonb_set(v_breaks, array[(v_len - 1)::text, 'end_at'], to_jsonb(now()))
   where id = p_entry_id
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke all on function public.start_time_entry_break(uuid, text) from public, anon;
revoke all on function public.end_time_entry_break(uuid) from public, anon;
grant execute on function public.start_time_entry_break(uuid, text) to authenticated;
grant execute on function public.end_time_entry_break(uuid) to authenticated;
