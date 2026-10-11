-- Review fixes: tenant integrity, chat/BEO/push/AI/time-clock hardening.
--
-- Every function redefined here is written out in full with CREATE OR REPLACE, the same
-- signature and language as its latest prior definition, SECURITY DEFINER, and
-- `set search_path = ''` (fully qualified names throughout). CREATE OR REPLACE keeps the
-- existing ACL; grants are restated where they were explicit.
--
-- Existing-data policy: no constraint is added that existing rows could violate. Where a
-- rule would reject rows already on disk, it is enforced on new writes only, via a trigger
-- that fires on INSERT or on UPDATE of the relevant columns. Rows untouched by a write keep
-- working as they did before this migration.

-- -----------------------------------------------------------------------------
-- 1. venues: organization_id is immutable once set (org admins could move a venue)
-- -----------------------------------------------------------------------------
create or replace function app_hidden.guard_venue_organization_immutable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception 'a venue cannot be moved to another organization' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.guard_venue_organization_immutable() from public, anon, authenticated;

drop trigger if exists zz_venues_organization_immutable on public.venues;
create trigger zz_venues_organization_immutable
  before update of organization_id on public.venues
  for each row execute function app_hidden.guard_venue_organization_immutable();

-- -----------------------------------------------------------------------------
-- 13. shifts / events / shift_insights / checklist_completions: venue_id is immutable
-- (verified: no migration updates venue_id on these tables; guard_review_row_update
-- already covers shift_swaps, operational_tasks, incidents and time_entries.)
-- -----------------------------------------------------------------------------
create or replace function app_hidden.guard_venue_row_immutable()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.venue_id is distinct from old.venue_id then
    raise exception 'venue_id cannot be changed once set' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.guard_venue_row_immutable() from public, anon, authenticated;

drop trigger if exists zz_shifts_venue_immutable on public.shifts;
create trigger zz_shifts_venue_immutable
  before update of venue_id on public.shifts
  for each row execute function app_hidden.guard_venue_row_immutable();

drop trigger if exists zz_events_venue_immutable on public.events;
create trigger zz_events_venue_immutable
  before update of venue_id on public.events
  for each row execute function app_hidden.guard_venue_row_immutable();

drop trigger if exists zz_shift_insights_venue_immutable on public.shift_insights;
create trigger zz_shift_insights_venue_immutable
  before update of venue_id on public.shift_insights
  for each row execute function app_hidden.guard_venue_row_immutable();

drop trigger if exists zz_checklist_completions_venue_immutable on public.checklist_completions;
create trigger zz_checklist_completions_venue_immutable
  before update of venue_id on public.checklist_completions
  for each row execute function app_hidden.guard_venue_row_immutable();

-- -----------------------------------------------------------------------------
-- 2. Removed staff lose conversation access
-- (a) Deleting a membership removes that user's conversation_members rows for every
--     conversation the membership covered and no remaining membership still covers.
--     Venue-level removal covers that venue's conversations; org-level removal covers the
--     org's conversations. all_staff channels use venue membership directly, so they need
--     no row; group and DM rows are removed here.
-- (b) is_conversation_member also requires live membership coverage (below), so a
--     stale row can never grant access.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.revoke_removed_conversation_access()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.conversation_members cm
  using public.conversations c
  where cm.user_id = old.user_id
    and c.id = cm.conversation_id
    and c.organization_id = old.organization_id
    and (old.venue_id is null or c.venue_id = old.venue_id)
    and not exists (
      select 1
      from public.memberships m
      where m.user_id = old.user_id
        and m.organization_id = c.organization_id
        and (m.venue_id is null or m.venue_id = c.venue_id)
    );
  return old;
end;
$$;

revoke all on function app_hidden.revoke_removed_conversation_access() from public, anon, authenticated;

drop trigger if exists trg_memberships_revoke_conversations on public.memberships;
create trigger trg_memberships_revoke_conversations
  after delete on public.memberships
  for each row execute function app_hidden.revoke_removed_conversation_access();

-- (b) Same signature, language and search_path as before. Membership must still cover the
-- conversation's venue (venue-level row for that venue, or an org-level row).
create or replace function app_hidden.is_conversation_member(
  p_conv_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id
    where cm.conversation_id = p_conv_id
      and cm.user_id = coalesce(p_user_id, auth.uid())
      and exists (
        select 1
        from public.memberships m
        where m.user_id = cm.user_id
          and m.organization_id = c.organization_id
          and (m.venue_id is null or m.venue_id = c.venue_id)
      )
  );
$$;

-- -----------------------------------------------------------------------------
-- 11. create_or_get_dm: reject self-DMs and serialize per user pair
-- -----------------------------------------------------------------------------
create or replace function public.create_or_get_dm(
  p_venue_id uuid,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_id uuid := auth.uid();
  v_conv_id uuid;
  v_org_id uuid;
begin
  if v_caller_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: caller is not a member of this venue' using errcode = '42501';
  end if;

  if p_target_user_id is null or p_target_user_id = v_caller_id then
    raise exception 'a direct message needs a different user' using errcode = '22023';
  end if;

  -- Serialize concurrent first-contact calls for the same pair so only one DM is created.
  perform pg_advisory_xact_lock(hashtextextended(
    'dm:' || least(v_caller_id, p_target_user_id)::text || ':' || greatest(v_caller_id, p_target_user_id)::text,
    0
  ));

  -- Look for existing 2-person DM conversation containing both users
  select c.id into v_conv_id
  from public.conversations c
  join public.conversation_members m1 on m1.conversation_id = c.id and m1.user_id = v_caller_id
  join public.conversation_members m2 on m2.conversation_id = c.id and m2.user_id = p_target_user_id
  where c.venue_id = p_venue_id
    and c.type = 'dm'
  limit 1;

  if v_conv_id is not null then
    return v_conv_id;
  end if;

  select organization_id into v_org_id from public.venues where id = p_venue_id;

  -- Create new DM conversation
  insert into public.conversations (venue_id, organization_id, type)
  values (p_venue_id, v_org_id, 'dm')
  returning id into v_conv_id;

  -- Add both members
  insert into public.conversation_members (conversation_id, user_id, venue_id, organization_id)
  values
    (v_conv_id, v_caller_id, p_venue_id, v_org_id),
    (v_conv_id, p_target_user_id, p_venue_id, v_org_id);

  return v_conv_id;
end;
$$;

revoke execute on function public.create_or_get_dm(uuid, uuid) from public, anon;
grant execute on function public.create_or_get_dm(uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 17. conversation_reads: writes require current conversation membership.
-- The derive trigger now also runs on UPDATE, so a moved conversation_id re-derives
-- venue_id and organization_id.
-- -----------------------------------------------------------------------------
drop policy if exists conversation_reads_write on public.conversation_reads;
create policy conversation_reads_write on public.conversation_reads
  for all to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and app_hidden.is_conversation_member(conversation_id, auth.uid())
  );

drop trigger if exists trg_conversation_reads_derive on public.conversation_reads;
create trigger trg_conversation_reads_derive
  before insert or update on public.conversation_reads
  for each row
  execute function app_hidden.conversation_reads_derive();

-- -----------------------------------------------------------------------------
-- 8. unregister_push_token: a user may only disable their own registrations
-- -----------------------------------------------------------------------------
create or replace function public.unregister_push_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_token is null or char_length(p_token) < 16 or char_length(p_token) > 4096 then
    raise exception 'Invalid device token' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('push-token-revoke:' || p_token));
  update public.push_tokens
  set enabled = false, disabled_at = now(), updated_at = now()
  where token = p_token and enabled and user_id = auth.uid();
end;
$$;

revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 9. register_push_token: REVERTED (not changed by this migration). The shared-device
-- sign-in flow requires a live device token to transfer ownership on registration
-- (notifications_rls test 5-6; the offline sign-out case in apps/mobile depends on it).
-- Trade-off left open: any authenticated venue member who presents a live token can take
-- over its registration. Product decision needed; see report.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 10. commit_ai_reservation: an expired pending reservation cannot be committed
-- -----------------------------------------------------------------------------
create or replace function public.commit_ai_reservation(
  p_reservation_id uuid,
  p_organization_id uuid,
  p_venue_id uuid,
  p_user_id uuid,
  p_task text,
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cost_usd numeric
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.ai_budget_reservations;
begin
  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_organization_id::text));
  select * into v_reservation
  from public.ai_budget_reservations
  where id = p_reservation_id
  for update;

  if not found or v_reservation.organization_id <> p_organization_id then
    raise exception 'AI reservation not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.ai_usage_events where reservation_id = p_reservation_id) then
    return;
  end if;
  if v_reservation.status <> 'pending' then
    raise exception 'AI reservation is no longer pending' using errcode = '22023';
  end if;
  if v_reservation.expires_at < now() then
    raise exception 'AI reservation expired' using errcode = '22023';
  end if;
  if p_cost_usd < 0 or p_input_tokens < 0 or p_output_tokens < 0 then
    raise exception 'invalid AI usage values' using errcode = '22023';
  end if;

  update public.ai_budget_reservations set status = 'committed'
  where id = p_reservation_id;
  insert into public.ai_usage_events (
    organization_id, venue_id, user_id, task, model,
    input_tokens, output_tokens, cost_usd, reservation_id
  ) values (
    p_organization_id, p_venue_id, p_user_id, p_task, p_model,
    p_input_tokens, p_output_tokens, p_cost_usd, p_reservation_id
  );
end;
$$;

revoke all on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  from public, anon, authenticated;
grant execute on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  to service_role;

-- -----------------------------------------------------------------------------
-- 6. reservations.beo_id must reference a BEO in the same venue (new writes only)
-- -----------------------------------------------------------------------------
create or replace function app_hidden.enforce_reservation_beo_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_beo_venue_id uuid;
begin
  if new.beo_id is null then
    return new;
  end if;

  select venue_id into v_beo_venue_id
  from public.crm_beos
  where id = new.beo_id;

  if v_beo_venue_id is distinct from new.venue_id then
    raise exception 'BEO must belong to the reservation venue' using errcode = '23503';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.enforce_reservation_beo_scope() from public, anon, authenticated;

drop trigger if exists zz_reservations_beo_scope on public.reservations;
create trigger zz_reservations_beo_scope
  before insert or update of beo_id, venue_id on public.reservations
  for each row execute function app_hidden.enforce_reservation_beo_scope();

-- -----------------------------------------------------------------------------
-- 7. BEO-vs-BEO overlap: NOT CHANGED. Already enforced by
-- 20261010155000 (zz_reservations_beo_hold): every confirmed BEO writes a reservation hold,
-- and that guard rejects it when any other confirmed BEO overlaps, regardless of the
-- other BEO's hold status. Regression test in review_fixes.test.sql (F7).
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 12. Fully signed contracts: freeze the remaining client-facing terms
-- -----------------------------------------------------------------------------
create or replace function app_hidden.crm_contracts_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_lead_venue_id uuid;
  v_beo_venue_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;

    if new.lead_id is not null then
      select venue_id into v_lead_venue_id from public.crm_leads where id = new.lead_id;
      if v_lead_venue_id is null or v_lead_venue_id <> new.venue_id then
        raise exception 'lead % does not belong to venue %', new.lead_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    if new.beo_id is not null then
      select venue_id into v_beo_venue_id from public.crm_beos where id = new.beo_id;
      if v_beo_venue_id is null or v_beo_venue_id <> new.venue_id then
        raise exception 'beo % does not belong to venue %', new.beo_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    if new.contract_number is null or char_length(trim(new.contract_number)) = 0 then
      new.contract_number := 'C-' || upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 9));
    end if;

    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;

    -- Once fully_signed, content is frozen and the only legal status moves are to
    -- cancelled or disputed.
    if old.status = 'fully_signed' then
      if new.event_name is distinct from old.event_name
        or new.event_date is distinct from old.event_date
        or new.guest_count is distinct from old.guest_count
        or new.venue_space is distinct from old.venue_space
        or new.fb_minimum_cents is distinct from old.fb_minimum_cents
        or new.custom_clauses is distinct from old.custom_clauses
        or new.cancellation_policy is distinct from old.cancellation_policy
        or new.payment_schedule is distinct from old.payment_schedule
        or new.client_signature_name is distinct from old.client_signature_name
        or new.client_signature_date is distinct from old.client_signature_date
        or new.contract_date is distinct from old.contract_date
        or new.force_majeure is distinct from old.force_majeure
        or new.liability_waiver is distinct from old.liability_waiver
        or new.lead_id is distinct from old.lead_id
        or new.beo_id is distinct from old.beo_id
      then
        raise exception 'a fully signed contract cannot be modified; issue an amendment or cancel the contract' using errcode = '42501';
      end if;
      if new.status is distinct from old.status and new.status not in ('cancelled', 'disputed') then
        raise exception 'a fully signed contract can only move to cancelled or disputed' using errcode = '42501';
      end if;
    end if;

    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 14. floor_tables: the floor plan must belong to the table's venue (new writes only)
-- -----------------------------------------------------------------------------
create or replace function app_hidden.enforce_floor_table_plan_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_venue_id uuid;
begin
  select venue_id into v_plan_venue_id
  from public.floor_plans
  where id = new.floor_plan_id;

  if v_plan_venue_id is distinct from new.venue_id then
    raise exception 'floor plan must belong to the table venue' using errcode = '23503';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.enforce_floor_table_plan_scope() from public, anon, authenticated;

drop trigger if exists zz_floor_tables_plan_scope on public.floor_tables;
create trigger zz_floor_tables_plan_scope
  before insert or update of floor_plan_id, venue_id on public.floor_tables
  for each row execute function app_hidden.enforce_floor_table_plan_scope();

-- -----------------------------------------------------------------------------
-- 15. Connection secrets: anon has no business reading these tables at all. Authenticated
-- keeps its column-level grants (non-secret columns) from the earlier migrations.
-- -----------------------------------------------------------------------------
revoke all on public.payroll_connections from anon;
revoke all on public.pos_connections from anon;
revoke all on public.reservation_connections from anon;

-- -----------------------------------------------------------------------------
-- 16. Reservation deposit payment state is written by trusted payment paths only.
-- Client JWT writes may keep deposit_status at 'none' or 'required' (the app writes
-- 'required' on create) but cannot enter or leave payment states, or set payment ids or
-- timestamps. Writes with no JWT (service role, definer paths) are unrestricted.
-- Trade-off: no org-owner exception exists yet; a future payment path must run server-side.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.guard_reservation_deposit_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.deposit_status not in ('none', 'required')
       or new.deposit_paid_at is not null
       or new.deposit_payment_intent_id is not null
       or new.deposit_checkout_session_id is not null then
      raise exception 'deposit payment state is set by the payment flow only' using errcode = '42501';
    end if;
  else
    if new.deposit_status is distinct from old.deposit_status
       and (old.deposit_status not in ('none', 'required')
            or new.deposit_status not in ('none', 'required')) then
      raise exception 'deposit payment state is set by the payment flow only' using errcode = '42501';
    end if;
    if new.deposit_paid_at is distinct from old.deposit_paid_at
       or new.deposit_payment_intent_id is distinct from old.deposit_payment_intent_id
       or new.deposit_checkout_session_id is distinct from old.deposit_checkout_session_id then
      raise exception 'deposit payment state is set by the payment flow only' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.guard_reservation_deposit_state() from public, anon, authenticated;

drop trigger if exists zz_reservations_deposit_state on public.reservations;
create trigger zz_reservations_deposit_state
  before insert or update of deposit_status, deposit_paid_at, deposit_payment_intent_id, deposit_checkout_session_id
  on public.reservations
  for each row execute function app_hidden.guard_reservation_deposit_state();

-- -----------------------------------------------------------------------------
-- 3 & 18. Time clock: closing requires device location; appended breaks closed on clock-out
-- -----------------------------------------------------------------------------
create or replace function app_hidden.enforce_time_entry_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue record;
  v_dist double precision;
  v_correcting boolean := coalesce(current_setting('app.time_entry_correction', true), '') = 'on';
  v_old_breaks jsonb := coalesce(old.breaks, '[]'::jsonb);
  v_new_breaks jsonb := coalesce(new.breaks, '[]'::jsonb);
  v_old_len int := jsonb_array_length(v_old_breaks);
  v_new_len int := jsonb_array_length(v_new_breaks);
  v_changed boolean;
  i int;
  v_last jsonb;
begin
  if new.organization_id is distinct from old.organization_id
     or new.venue_id is distinct from old.venue_id
     or new.user_id is distinct from old.user_id
     or new.clock_in_at is distinct from old.clock_in_at
     or new.clock_in_lat is distinct from old.clock_in_lat
     or new.clock_in_lng is distinct from old.clock_in_lng
     or new.clock_in_accuracy_m is distinct from old.clock_in_accuracy_m
     or new.clock_in_mocked is distinct from old.clock_in_mocked
  then
    raise exception 'clock-in fields and ownership are immutable' using errcode = '42501';
  end if;

  if v_correcting then
    new.updated_at := now();
    return new;
  end if;

  if not old.is_open then
    raise exception 'this time entry is closed; use a manager correction to change it'
      using errcode = '42501';
  end if;

  if not new.is_open then
    new.clock_out_at := now();

    if new.clock_out_mocked then
      raise exception 'Mocked locations are not allowed' using errcode = '42501';
    end if;

    if new.clock_out_accuracy_m is not null and new.clock_out_accuracy_m > 50.0 then
      raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
    end if;

    -- Staff must close with a location fix, as they must clock in with one. Managers closing
    -- an entry for a team member (remote close) are exempt, as before.
    if not app_hidden.has_venue_role(
      new.venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    ) then
      if new.clock_out_lat is null or new.clock_out_lng is null or new.clock_out_accuracy_m is null then
        raise exception 'Clock-out location and accuracy are required' using errcode = '42501';
      end if;
    end if;

    select id, latitude, longitude, geofence_radius_m
    into v_venue
    from public.venues
    where id = new.venue_id;

    if new.clock_out_lat is not null and new.clock_out_lng is not null
       and v_venue.latitude is not null and v_venue.longitude is not null
       and not (v_venue.latitude = 0.0 and v_venue.longitude = 0.0) then
      v_dist := app_hidden.haversine_distance_m(
        new.clock_out_lat,
        new.clock_out_lng,
        v_venue.latitude,
        v_venue.longitude
      );
      if v_dist > v_venue.geofence_radius_m then
        raise exception 'You are outside the venue geofence' using errcode = '42501';
      end if;
    end if;

    v_new_breaks := coalesce(new.breaks, '[]'::jsonb);
    v_new_len := jsonb_array_length(v_new_breaks);
    if v_new_len > 0 then
      v_last := v_new_breaks -> (v_new_len - 1);
      if (v_last ? 'end_at') = false or v_last -> 'end_at' = 'null'::jsonb then
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    end if;
  end if;

  v_changed := v_new_len <> v_old_len;
  if not v_changed then
    for i in 0 .. v_old_len - 1 loop
      if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
        v_changed := true;
        exit;
      end if;
    end loop;
  end if;

  if v_changed then
    if v_new_len = v_old_len and v_new_len > 0 then
      for i in 0 .. v_old_len - 2 loop
        if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if (v_old_breaks -> (v_old_len - 1) ->> 'end_at') is not null then
        raise exception 'no open break to close' using errcode = '42501';
      end if;
      if not app_hidden.break_type_and_start_equal(
        v_new_breaks -> (v_old_len - 1), v_old_breaks -> (v_old_len - 1)
      ) then
        raise exception 'only a break''s end time may be set' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
    elsif v_new_len = v_old_len + 1 then
      for i in 0 .. v_old_len - 1 loop
        if not app_hidden.break_entries_equal(v_new_breaks -> i, v_old_breaks -> i) then
          raise exception 'historical breaks cannot be modified' using errcode = '42501';
        end if;
      end loop;
      if v_old_len > 0 and (v_old_breaks -> (v_old_len - 1) ->> 'end_at') is null then
        raise exception 'a break is already open' using errcode = '42501';
      end if;
      v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'start_at'], to_jsonb(now()));
      if new.is_open then
        -- Still open: the new break stays open until it is explicitly closed.
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], 'null'::jsonb);
      else
        -- Clock-out with an appended break: close it at server time instead of reopening it.
        -- The start is server-forced to now(), so a client end time earlier than that would
        -- yield negative paid time; server time is used in its place.
        v_new_breaks := jsonb_set(v_new_breaks, array[(v_new_len - 1)::text, 'end_at'], to_jsonb(now()));
      end if;
    else
      raise exception 'breaks can only be appended to or have their open entry closed'
        using errcode = '42501';
    end if;
  end if;
  new.breaks := v_new_breaks;

  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. correct_time_entry: sane clock-out window, and no self-correction
-- -----------------------------------------------------------------------------
create or replace function public.correct_time_entry(
  p_entry_id uuid,
  p_clock_out_at timestamptz default null,
  p_breaks jsonb default null,
  p_reason text default null
) returns public.time_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.time_entries;
  v_before jsonb;
begin
  select * into v_entry from public.time_entries where id = p_entry_id;
  if v_entry.id is null then
    raise exception 'time entry % does not exist', p_entry_id using errcode = 'P0002';
  end if;

  if not app_hidden.has_venue_role(
    v_entry.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: only managers can correct time entries' using errcode = '42501';
  end if;

  if v_entry.user_id = auth.uid() then
    raise exception 'managers cannot correct their own time entries' using errcode = '42501';
  end if;

  if p_clock_out_at is not null then
    if p_clock_out_at <= v_entry.clock_in_at then
      raise exception 'clock-out must be after clock-in' using errcode = '22023';
    end if;
    if p_clock_out_at > now() + interval '1 minute' then
      raise exception 'clock-out cannot be in the future' using errcode = '22023';
    end if;
  end if;

  v_before := to_jsonb(v_entry);

  -- Lets this one statement through the otherwise-blanket "closed entries are immutable"
  -- and breaks-validation rules in app_hidden.enforce_time_entry_update, for this
  -- transaction only.
  perform set_config('app.time_entry_correction', 'on', true);

  update public.time_entries
  set
    clock_out_at = coalesce(p_clock_out_at, clock_out_at),
    is_open = case when p_clock_out_at is not null then false else is_open end,
    breaks = coalesce(p_breaks, breaks)
  where id = p_entry_id
  returning * into v_entry;

  insert into public.audit_log (
    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata
  ) values (
    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',
    'time_entries', v_entry.id,
    jsonb_build_object('before', v_before, 'after', to_jsonb(v_entry), 'reason', p_reason)
  );

  return v_entry;
end;
$$;

revoke execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.correct_time_entry(uuid, timestamptz, jsonb, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 5 & 19. prepare_time_entry_insert: user and shift must belong to the venue; the
-- anti-replay boundary is the venue-local midnight as a timestamptz.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.prepare_time_entry_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue record;
  v_dist double precision;
  v_prior_match record;
begin
  select id, organization_id, latitude, longitude, geofence_radius_m, timezone
  into v_venue
  from public.venues
  where id = new.venue_id;

  if v_venue.id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;

  new.organization_id := v_venue.organization_id;
  if not app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) or new.user_id is null then
    new.user_id := auth.uid();
  end if;

  -- A manager may record a punch for someone else only if that person belongs to this
  -- venue (venue-level row) or organization (org-level row).
  if new.user_id is distinct from auth.uid() and not exists (
    select 1
    from public.memberships m
    where m.user_id = new.user_id
      and m.organization_id = v_venue.organization_id
      and (m.venue_id = new.venue_id or m.venue_id is null)
  ) then
    raise exception 'time entry user must belong to the same venue' using errcode = '23503';
  end if;

  if new.shift_id is not null and not exists (
    select 1
    from public.shifts s
    where s.id = new.shift_id
      and s.venue_id = new.venue_id
  ) then
    raise exception 'shift must belong to the same venue' using errcode = '23503';
  end if;

  -- Always server time: a supplied clock_in_at is never trusted, including from managers
  -- recording a walk-in punch for someone else. Backdated corrections go through
  -- public.correct_time_entry instead, where they're audited.
  new.clock_in_at := now();
  new.is_open := true;
  new.clock_out_at := null;

  if new.clock_in_mocked then
    raise exception 'Mocked locations are not allowed' using errcode = '42501';
  end if;

  if new.clock_in_accuracy_m > 50.0 then
    raise exception 'Location accuracy must be 50m or better' using errcode = '42501';
  end if;

  -- Geofence check
  if v_venue.latitude is not null and v_venue.longitude is not null
     and not (v_venue.latitude = 0.0 and v_venue.longitude = 0.0) then
    v_dist := app_hidden.haversine_distance_m(
      new.clock_in_lat,
      new.clock_in_lng,
      v_venue.latitude,
      v_venue.longitude
    );
    if v_dist > v_venue.geofence_radius_m then
      raise exception 'You are outside the venue geofence' using errcode = '42501';
    end if;
  end if;

  -- Anti-replay check against punches from earlier venue-local calendar days. The boundary
  -- is venue-local midnight as a timestamptz, not a session-timezone-dependent comparison.
  select clock_in_lat, clock_in_lng, clock_in_accuracy_m
  into v_prior_match
  from public.time_entries
  where user_id = new.user_id
    and clock_in_at < (
      ((now() at time zone coalesce(v_venue.timezone, 'UTC'))::date)::timestamp
        at time zone coalesce(v_venue.timezone, 'UTC')
    )
    and clock_in_lat = new.clock_in_lat
    and clock_in_lng = new.clock_in_lng
  limit 1;

  if v_prior_match is not null then
    if new.clock_in_accuracy_m <= 10.0 then
      raise exception 'This location reading is identical to an earlier punch and reports satellite-grade accuracy' using errcode = '42501';
    else
      new.location_anomaly := 'repeated_fix';
    end if;
  end if;

  return new;
end;
$$;
