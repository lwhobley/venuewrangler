-- Keep optional guest and staff references inside the owning venue's tenant scope.
-- Existing rows are deliberately not rewritten: live-data reconciliation must precede
-- applying this migration to an existing database.

create or replace function app_hidden.enforce_venue_guest_reference()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guest_venue_id uuid;
begin
  if new.guest_id is null then
    return new;
  end if;

  select g.venue_id into v_guest_venue_id
  from public.guests g
  where g.id = new.guest_id;

  if v_guest_venue_id is null or v_guest_venue_id <> new.venue_id then
    raise exception 'guest reference must belong to the same venue'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

drop trigger if exists zz_reservations_guest_scope on public.reservations;
create trigger zz_reservations_guest_scope
before insert or update of guest_id, venue_id on public.reservations
for each row execute function app_hidden.enforce_venue_guest_reference();

drop trigger if exists zz_crm_leads_guest_scope on public.crm_leads;
create trigger zz_crm_leads_guest_scope
before insert or update of guest_id, venue_id on public.crm_leads
for each row execute function app_hidden.enforce_venue_guest_reference();

create or replace function app_hidden.enforce_venue_staff_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assigned_user_id uuid;
  v_org_id uuid;
  v_venue_id uuid;
begin
  v_assigned_user_id := nullif(to_jsonb(new)->>case
    when tg_table_name = 'shifts' then 'staff_id'
    else 'assigned_to'
  end, '')::uuid;
  if v_assigned_user_id is null then
    return new;
  end if;

  v_venue_id := (to_jsonb(new)->>'venue_id')::uuid;
  v_org_id := (to_jsonb(new)->>'organization_id')::uuid;
  if v_venue_id is null or v_org_id is null or not exists (
    select 1
    from public.memberships m
    where m.user_id = v_assigned_user_id
      and m.organization_id = v_org_id
      and (m.venue_id = v_venue_id or m.venue_id is null)
  ) then
    raise exception 'assigned staff member must belong to the same venue'
      using errcode = '23503';
  end if;
  return new;
end;
$$;

drop trigger if exists zz_shifts_staff_scope on public.shifts;
create trigger zz_shifts_staff_scope
before insert or update of staff_id, venue_id, organization_id on public.shifts
for each row execute function app_hidden.enforce_venue_staff_assignment();

drop trigger if exists zz_tasks_staff_scope on public.operational_tasks;
create trigger zz_tasks_staff_scope
before insert or update of assigned_to, venue_id, organization_id on public.operational_tasks
for each row execute function app_hidden.enforce_venue_staff_assignment();

drop trigger if exists zz_reservations_staff_scope on public.reservations;
create trigger zz_reservations_staff_scope
before insert or update of assigned_to, venue_id, organization_id on public.reservations
for each row execute function app_hidden.enforce_venue_staff_assignment();

drop trigger if exists zz_crm_leads_staff_scope on public.crm_leads;
create trigger zz_crm_leads_staff_scope
before insert or update of assigned_to, venue_id, organization_id on public.crm_leads
for each row execute function app_hidden.enforce_venue_staff_assignment();

revoke all on function app_hidden.enforce_venue_guest_reference() from public, anon, authenticated;
revoke all on function app_hidden.enforce_venue_staff_assignment() from public, anon, authenticated;

-- A device token is transferable on sign-in (register_push_token already transfers ownership
-- for a venue). Permit an authenticated app holding that token to revoke its old registration
-- before registering the same device under a different signed-in account.
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
  where token = p_token and enabled;
end;
$$;

revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;
