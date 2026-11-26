-- Security review fixes (2026-11-25): F04, F08, F13, F14. See docs/security/security-review-2026-11-25.md.
-- F02 (geofence required) was already enforced by app_hidden.require_clock_in_location
-- (20261023101510_launch_review_workflows.sql), so nothing is added for it here.

-- ---------------------------------------------------------------------------
-- F04: MFA (aal2) for sensitive operations, behind the existing
-- platform_settings.require_mfa_for_admin_actions switch (app_hidden.mfa_satisfied()).
-- ---------------------------------------------------------------------------
-- Edge Functions (Stripe checkout/portal, payroll OAuth connect, BrightHR connect/disconnect) ask
-- this with the caller's own JWT before acting.
create or replace function public.caller_mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and app_hidden.mfa_satisfied();
$$;

revoke all on function public.caller_mfa_satisfied() from public, anon;
grant execute on function public.caller_mfa_satisfied() to authenticated;

-- Wage and leave-balance edits need a verified second factor when the switch is on.
create or replace function app_hidden.require_mfa_for_wage_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or app_hidden.account_deletion_in_progress() then
    return new;
  end if;
  if (tg_op = 'INSERT' and (new.hourly_rate_cents is not null or new.pto_hours <> 0 or new.sick_hours <> 0))
     or (tg_op = 'UPDATE' and (
       new.hourly_rate_cents is distinct from old.hourly_rate_cents
       or new.pto_hours is distinct from old.pto_hours
       or new.sick_hours is distinct from old.sick_hours)) then
    if not app_hidden.mfa_satisfied() then
      raise exception 'mfa_required' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.require_mfa_for_wage_change() from public, anon, authenticated;

drop trigger if exists require_mfa_for_wage_change on public.employee_hr_profiles;
create trigger require_mfa_for_wage_change
  before insert or update on public.employee_hr_profiles
  for each row execute function app_hidden.require_mfa_for_wage_change();

-- ---------------------------------------------------------------------------
-- F08: merging and splitting tables reshapes the service floor; supervisors and up only.
-- Seating guests (assign_tables_to_reservation) stays open to all venue staff (hosts).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.merge_floor_tables(p_venue_id uuid, p_table_ids uuid[], p_party_size integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_merge_group_id uuid;

  v_table_id uuid;

  v_table_count int;

begin

  -- Role authorization check

  if not app_hidden.has_venue_role(

    p_venue_id,

    array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';

  end if;



  if array_length(p_table_ids, 1) is null or array_length(p_table_ids, 1) < 2 then

    raise exception 'invalid_tables: select at least two tables to merge' using errcode = '22023';

  end if;



  -- Acquire advisory transaction locks on all tables sorted by UUID to prevent deadlocks

  for v_table_id in

    select unnest(p_table_ids) order by 1

  loop

    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));

  end loop;



  -- Verify all tables belong to this venue

  select count(*) into v_table_count

  from public.floor_tables

  where venue_id = p_venue_id and id = any(p_table_ids);



  if v_table_count <> array_length(p_table_ids, 1) then

    raise exception 'invalid_table_selection: one or more tables do not belong to this venue' using errcode = '42501';

  end if;



  v_merge_group_id := gen_random_uuid();



  update public.floor_tables

  set

    merge_group_id = v_merge_group_id,

    party_size = coalesce(p_party_size, party_size),

    last_activity_at = now(),

    updated_at = now()

  where venue_id = p_venue_id and id = any(p_table_ids);



  return v_merge_group_id;

end;

$function$;

CREATE OR REPLACE FUNCTION public.split_floor_tables(p_venue_id uuid, p_merge_group_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_table_id uuid;

begin

  if not app_hidden.has_venue_role(

    p_venue_id,

    array['supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';

  end if;



  for v_table_id in

    select id from public.floor_tables where venue_id = p_venue_id and merge_group_id = p_merge_group_id order by id

  loop

    perform pg_advisory_xact_lock(hashtext('floor-table:' || p_venue_id::text || ':' || v_table_id::text));

  end loop;



  update public.floor_tables

  set

    merge_group_id = null,

    last_activity_at = now(),

    updated_at = now()

  where venue_id = p_venue_id and merge_group_id = p_merge_group_id;

end;

$function$;

-- ---------------------------------------------------------------------------
-- F14: manager RPCs answered "not found" before checking authority, so any member could probe
-- whether an id from another tenant exists. A missing row now gets the same 42501 as a
-- forbidden one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.correct_time_entry(p_entry_id uuid, p_clock_out_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_breaks jsonb DEFAULT NULL::jsonb, p_reason text DEFAULT NULL::text)
 RETURNS time_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_entry public.time_entries;

  v_before jsonb;

begin

  select * into v_entry from public.time_entries where id = p_entry_id;

  if v_entry.id is null then

    raise exception 'forbidden: only managers can correct time entries' using errcode = '42501';

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



  v_before := app_hidden.scrub_time_entry_json(to_jsonb(v_entry));



  perform app_hidden.open_privilege_gate('time_entry_correction');



  update public.time_entries

  set

    clock_out_at = coalesce(p_clock_out_at, clock_out_at),

    is_open = case when p_clock_out_at is not null then false else is_open end,

    breaks = coalesce(p_breaks, breaks)

  where id = p_entry_id

  returning * into v_entry;



  perform app_hidden.close_privilege_gate('time_entry_correction');



  insert into public.audit_log (

    organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata

  ) values (

    v_entry.organization_id, v_entry.venue_id, auth.uid(), 'time_entry.correct',

    'time_entries', v_entry.id,

    jsonb_build_object(

      'before', v_before,

      'after', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)),

      'reason', p_reason

    )

  );



  return v_entry;

end;

$function$;

CREATE OR REPLACE FUNCTION public.void_time_entry(p_time_entry_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_entry public.time_entries;

  v_reason text := trim(coalesce(p_reason, ''));

begin

  select * into v_entry from public.time_entries where id = p_time_entry_id for update;

  if not found then

    raise exception 'forbidden: only managers can void time entries' using errcode = '42501';

  end if;



  if auth.uid() is null or not app_hidden.has_venue_role(

    v_entry.venue_id,

    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden: only managers can void time entries' using errcode = '42501';

  end if;



  if v_entry.user_id = auth.uid() then

    raise exception 'managers cannot void their own time entries' using errcode = '42501';

  end if;



  if char_length(v_reason) < 5 or char_length(v_reason) > 500 then

    raise exception 'a reason of 5-500 characters is required' using errcode = '22023';

  end if;



  perform app_hidden.audit_event(

    v_entry.organization_id, v_entry.venue_id, 'time_entry.void', 'time_entries', v_entry.id,

    jsonb_build_object('before', app_hidden.scrub_time_entry_json(to_jsonb(v_entry)), 'reason', v_reason)

  );



  delete from public.time_entries where id = v_entry.id;

end;

$function$;

CREATE OR REPLACE FUNCTION public.erase_guest(p_guest_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_g public.guests;

  v_leads uuid[];

begin

  select * into v_g from public.guests where id = p_guest_id for update;

  if not found then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if auth.uid() is null or not app_hidden.has_venue_role(

    v_g.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  update public.reservations r

     set guest_name = 'Erased guest', guest_phone = null, guest_email = null

   where r.venue_id = v_g.venue_id

     and (

       r.guest_id = v_g.id

       or (v_g.phone is not null and r.guest_phone = v_g.phone)

       or (v_g.email is not null and lower(r.guest_email) = lower(v_g.email))

     );



  select coalesce(array_agg(l.id), '{}') into v_leads

  from public.crm_leads l

  where l.venue_id = v_g.venue_id

    and (

      l.guest_id = v_g.id

      or (v_g.phone is not null and l.phone = v_g.phone)

      or (v_g.email is not null and lower(l.email) = lower(v_g.email))

    );



  delete from public.crm_notes where lead_id = any (v_leads);

  delete from public.crm_activity_log where lead_id = any (v_leads);

  update public.crm_leads

     set full_name = 'Erased lead', email = null, phone = null, company = null,

         tags = '{}', marketing_opt_in = false, deleted_at = coalesce(deleted_at, now())

   where id = any (v_leads);



  delete from public.guest_household_links where from_guest_id = v_g.id or to_guest_id = v_g.id;



  -- POS integrations do not link checks to guests yet, so most checks only carry the name the

  -- POS sent. Linked checks are matched by id (never another guest's); unlinked ones fall back

  -- to the display-name match, erring toward scrubbing for an erasure request.

  perform app_hidden.open_privilege_gate('pos_retention');

  update public.pos_checks

     set guest_name = null, raw_payload = null, guest_id = null

   where venue_id = v_g.venue_id

     and (

       guest_id = v_g.id

       or (

         guest_id is null

         and nullif(trim(v_g.full_name), '') is not null

         and lower(trim(guest_name)) = lower(trim(v_g.full_name))

       )

     );

  perform app_hidden.close_privilege_gate('pos_retention');



  delete from public.guests where id = v_g.id;



  perform app_hidden.audit_event(

    v_g.organization_id, v_g.venue_id, 'guest.erase', 'guests', v_g.id,

    jsonb_build_object('leads_anonymized', coalesce(array_length(v_leads, 1), 0))

  );

end;

$function$;

CREATE OR REPLACE FUNCTION public.revoke_invite(p_invite_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_invite public.invites;

begin

  if auth.uid() is null then

    raise exception 'Must be signed in' using errcode = '42501';

  end if;



  select * into v_invite from public.invites where id = p_invite_id for update;

  if not found then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if not app_hidden.has_venue_role(

    v_invite.venue_id,

    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if v_invite.status <> 'pending' then

    raise exception 'invite_not_pending' using errcode = 'P0001';

  end if;



  update public.invites set status = 'revoked' where id = v_invite.id;



  perform app_hidden.audit_event(

    v_invite.organization_id, v_invite.venue_id, 'invite.revoke', 'invites', v_invite.id,

    jsonb_build_object('email', v_invite.email, 'role', v_invite.role)

  );

end;

$function$;

CREATE OR REPLACE FUNCTION public.remove_or_cancel_shift(p_shift_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.shifts%rowtype;
begin
  select * into s from public.shifts where id = p_shift_id for update;
  if not found then raise exception 'forbidden_shift' using errcode = '42501'; end if;
  if not app_hidden.has_venue_role(s.venue_id,
      array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'forbidden_shift' using errcode = '42501';
  end if;
  if exists (select 1 from public.pos_external_shift_mappings
    where shift_id = s.id) then
    if s.status = 'completed' then
      raise exception 'completed_shift_cannot_cancel' using errcode = 'P0001';
    end if;
    update public.shifts set status = 'cancelled' where id = s.id;
    return 'cancelled';
  end if;
  delete from public.shifts where id = s.id;
  return 'deleted';
end $function$;

CREATE OR REPLACE FUNCTION public.change_member_role(p_membership_id uuid, p_new_role app_role)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_m public.memberships;

  v_org_level boolean;

begin

  if auth.uid() is null then

    raise exception 'Must be signed in' using errcode = '42501';

  end if;



  select * into v_m from public.memberships where id = p_membership_id for update;

  if not found then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  v_org_level := v_m.venue_id is null;

  if v_org_level and p_new_role not in ('organization_owner', 'organization_admin') then

    raise exception 'role_not_allowed' using errcode = 'P0001';

  end if;

  if not v_org_level and p_new_role not in ('venue_manager', 'supervisor', 'staff') then

    raise exception 'role_not_allowed' using errcode = 'P0001';

  end if;



  if p_new_role = v_m.role then

    return;

  end if;



  if v_m.user_id = auth.uid() then

    -- The only self-service change: an owner stepping down to admin while another owner remains.

    if not (v_m.role = 'organization_owner' and p_new_role = 'organization_admin') then

      raise exception 'cannot_modify_self' using errcode = 'P0001';

    end if;

  elsif not (

    app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, v_m.role)

    and app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, p_new_role)

  ) then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if (v_m.role in ('organization_owner', 'organization_admin', 'venue_manager')

      or p_new_role in ('organization_owner', 'organization_admin', 'venue_manager'))

     and not app_hidden.mfa_satisfied() then

    raise exception 'mfa_required' using errcode = '42501';

  end if;



  if v_m.role = 'organization_owner' and p_new_role <> 'organization_owner' and not exists (

    select 1 from public.memberships o

    where o.organization_id = v_m.organization_id and o.role = 'organization_owner' and o.id <> v_m.id

  ) then

    raise exception 'last_owner' using errcode = 'P0001';

  end if;



  update public.memberships set role = p_new_role where id = v_m.id;



  perform app_hidden.audit_event(

    v_m.organization_id, v_m.venue_id, 'member.change_role', 'memberships', v_m.id,

    jsonb_build_object('user_id', v_m.user_id, 'from', v_m.role, 'to', p_new_role)

  );

end;

$function$;

CREATE OR REPLACE FUNCTION public.remove_member(p_membership_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_m public.memberships;

begin

  if auth.uid() is null then

    raise exception 'Must be signed in' using errcode = '42501';

  end if;



  select * into v_m from public.memberships where id = p_membership_id for update;

  if not found then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if v_m.user_id = auth.uid() then

    raise exception 'cannot_modify_self' using errcode = 'P0001';

  end if;



  if not app_hidden.can_manage_member_role(v_m.organization_id, v_m.venue_id, v_m.role) then

    raise exception 'forbidden' using errcode = '42501';

  end if;



  if v_m.role in ('organization_owner', 'organization_admin', 'venue_manager')

     and not app_hidden.mfa_satisfied() then

    raise exception 'mfa_required' using errcode = '42501';

  end if;



  if v_m.role = 'organization_owner' and not exists (

    select 1 from public.memberships o

    where o.organization_id = v_m.organization_id and o.role = 'organization_owner' and o.id <> v_m.id

  ) then

    raise exception 'last_owner' using errcode = 'P0001';

  end if;



  delete from public.memberships where id = v_m.id;



  -- Stop pushes to every venue the user can no longer reach (a remaining org-level or

  -- venue-level membership keeps its own tokens working).

  update public.push_tokens pt

     set enabled = false, disabled_at = coalesce(pt.disabled_at, now())

   where pt.user_id = v_m.user_id

     and pt.organization_id = v_m.organization_id

     and pt.enabled

     and not exists (

       select 1 from public.memberships mm

       where mm.user_id = v_m.user_id

         and mm.organization_id = pt.organization_id

         and (mm.venue_id is null or mm.venue_id = pt.venue_id)

     );



  perform app_hidden.audit_event(

    v_m.organization_id, v_m.venue_id, 'member.remove', 'memberships', v_m.id,

    jsonb_build_object('user_id', v_m.user_id, 'role', v_m.role)

  );

end;

$function$;


-- ---------------------------------------------------------------------------
-- F13: every SECURITY DEFINER function still ran with search_path = public, which lets an object
-- created in public shadow a pg_catalog name the function relies on. Each body below has its
-- public references schema-qualified and the search_path pinned to ''. Generated from the live
-- definitions; behaviour is otherwise unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_hidden.crm_activity_log_derive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';

  end if;

  new.organization_id := v_org_id;

  new.created_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.crm_beos_derive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

  v_lead_venue_id uuid;

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



    new.updated_at := now();

    return new;

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.crm_leads_derive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  if tg_op = 'INSERT' then

    select organization_id into v_org_id from public.venues where id = new.venue_id;

    if v_org_id is null then

      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';

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

    new.updated_at := now();

    return new;

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.crm_leads_log_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  if new.status is distinct from old.status then

    insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)

    values (new.venue_id, new.id, auth.uid(), 'status_changed', old.status || ' -> ' || new.status);

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.crm_notes_derive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_lead_venue_id uuid;

  v_lead_org_id uuid;

begin

  select venue_id, organization_id into v_lead_venue_id, v_lead_org_id

  from public.crm_leads where id = new.lead_id;



  if v_lead_venue_id is null then

    raise exception 'invalid_lead_id: lead does not exist' using errcode = '23503';

  end if;



  new.venue_id := v_lead_venue_id;

  new.organization_id := v_lead_org_id;

  new.author_id := auth.uid();

  new.created_at := now();



  update public.crm_leads

  set last_activity_at = now(), updated_at = now()

  where id = new.lead_id;



  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.crm_notes_log_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)

  values (new.venue_id, new.lead_id, new.author_id, 'note_added', left(new.text, 120));

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.disable_push_tokens(p_tokens text[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_count integer;

begin

  update public.push_tokens

  set enabled = false,

      disabled_at = now(),

      updated_at = now()

  where token = any(p_tokens)

    and enabled = true;



  get diagnostics v_count = row_count;

  return v_count;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.dispatch_account_deletion_job(p_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_url text;

  v_secret text;

begin

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'account_deletion_dispatch_url';

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'account_deletion_dispatch_secret';

  if v_url is null or v_secret is null then

    -- The retry sweep and public.ops_health_report() surface this; never fail the user's request.

    raise warning 'account deletion dispatch is not configured (vault secrets missing); job % stays queued', p_job_id;

    return;

  end if;



  perform net.http_post(

    url := v_url,

    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),

    body := jsonb_build_object('job_id', p_job_id),

    timeout_milliseconds := 5000

  );

exception when others then

  raise warning 'account deletion dispatch failed for job %: %', p_job_id, sqlerrm;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.dispatch_notification_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_url text;

  v_secret text;

begin

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_dispatch_url';

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_dispatch_secret';

  if v_url is null or v_secret is null then

    return new;

  end if;



  perform net.http_post(

    url := v_url,

    headers := jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', v_secret),

    body := jsonb_build_object('event_id', new.id),

    timeout_milliseconds := 5000

  );

  return new;

exception when others then

  -- A push failure must never roll back the business write that triggered it.

  raise warning 'notification push dispatch failed: %', sqlerrm;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.email_templates_derive()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  if tg_op = 'INSERT' then

    select organization_id into v_org_id from public.venues where id = new.venue_id;

    if v_org_id is null then

      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';

    end if;

    new.organization_id := v_org_id;

    new.created_at := now();

    new.updated_at := now();

    return new;

  elsif tg_op = 'UPDATE' then

    if new.venue_id <> old.venue_id then

      raise exception 'venue_id cannot be modified once set' using errcode = '42501';

    end if;

    new.updated_at := now();

    return new;

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.enforce_incident_update_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.reported_by is distinct from auth.uid() then
    raise exception 'not authorized to update this incident' using errcode = '42501';
  end if;

  if new.status is distinct from old.status
    or new.severity is distinct from old.severity
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.reported_by is distinct from old.reported_by
    or new.resolved_by is distinct from old.resolved_by
    or new.resolved_at is distinct from old.resolved_at
    or new.created_at is distinct from old.created_at
  then
    raise exception
      'the reporter may only edit title/description, and only while the incident is open'
      using errcode = '42501';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION app_hidden.enforce_shift_swap_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  -- Immutable columns are frozen for everyone, including managers.
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.shift_id is distinct from old.shift_id
    or new.requested_by is distinct from old.requested_by
    or new.offered_to is distinct from old.offered_to
    or new.created_at is distinct from old.created_at
  then
    raise exception 'only a swap request''s status and accepted_by may change' using errcode = '42501';
  end if;

  -- accepted, declined and cancelled are final, whoever is asking.
  if old.status <> 'pending' then
    raise exception 'this swap request is no longer pending' using errcode = '42501';
  end if;

  if new.status = 'accepted' and new.accepted_by is null then
    raise exception 'an accepted swap must record who accepted it' using errcode = '23514';
  end if;
  if new.status in ('declined', 'cancelled', 'pending')
     and new.accepted_by is distinct from old.accepted_by then
    raise exception 'accepted_by is set only when a swap is accepted' using errcode = '42501';
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if auth.uid() = old.requested_by then
    if new.status <> 'cancelled' then
      raise exception 'the requester may only cancel their own swap request' using errcode = '42501';
    end if;
  elsif new.status = 'declined' then
    if old.offered_to is null or old.offered_to <> auth.uid() then
      raise exception 'only the person this swap was offered to may decline it' using errcode = '42501';
    end if;
  else
    if new.status <> 'accepted' or new.accepted_by is distinct from auth.uid() then
      raise exception 'you may only accept this swap request as yourself' using errcode = '42501';
    end if;
    if old.offered_to is not null and old.offered_to <> auth.uid() then
      raise exception 'this swap request was offered to someone else' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION app_hidden.enforce_staff_request_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  -- Account deletion (public.request_account_deletion) clears this account from rows it

  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto

  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).

  if app_hidden.account_deletion_in_progress() then

    return new;

  end if;



  if app_hidden.has_venue_role(

       new.venue_id,

       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

     )

     and (

       auth.uid() is distinct from old.user_id

       or app_hidden.has_venue_role(new.venue_id, array['organization_owner']::public.app_role[])

     )

  then

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

$function$;

CREATE OR REPLACE FUNCTION app_hidden.enforce_task_update_scope()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- Account deletion (public.request_account_deletion) clears this account from rows it
  -- touched; these guards exist to stop a *client* editing them, and would otherwise veto
  -- that cleanup (and, for staff_requests, the reviewer_id SET NULL on the final auth delete).
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if app_hidden.has_venue_role(
    new.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    return new;
  end if;

  if old.assigned_to is distinct from auth.uid() then
    raise exception 'not authorized to update this task' using errcode = '42501';
  end if;

  if new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.venue_id is distinct from old.venue_id
    or new.organization_id is distinct from old.organization_id
    or new.assigned_to is distinct from old.assigned_to
    or new.due_at is distinct from old.due_at
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'the assignee may only change a task''s status' using errcode = '42501';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION app_hidden.enqueue_document_storage_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)

  values (old.organization_id, old.venue_id, 'staff-documents', old.storage_path);

  return old;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.enqueue_incident_attachment_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)

  values (old.organization_id, old.venue_id, 'incident-evidence', old.storage_path);

  return old;

exception when others then

  -- A malformed legacy path must not block deleting the incident; surface it instead.

  raise warning 'could not queue storage deletion for incident attachment %: %', old.id, sqlerrm;

  return old;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.has_org_role(p_org_id uuid, p_roles public.app_role[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    app_hidden.is_platform_admin()

    or exists (

      select 1 from public.memberships m

      where m.user_id = auth.uid()

        and m.organization_id = p_org_id

        and m.venue_id is null

        and m.role = any(p_roles)

    );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.has_venue_role(p_venue_id uuid, p_roles public.app_role[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    app_hidden.is_platform_admin()

    or exists (

      select 1

      from public.memberships m

      join public.venues v on v.id = p_venue_id

      where m.user_id = auth.uid()

        and (

          (m.venue_id = p_venue_id and m.role = any(p_roles))

          or (m.venue_id is null and m.organization_id = v.organization_id and m.role = any(p_roles))

        )

    );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.is_org_member(p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    app_hidden.is_platform_admin()

    or exists (

      select 1 from public.memberships m

      where m.user_id = auth.uid() and m.organization_id = p_org_id

    );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.is_platform_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select exists (

    select 1 from public.platform_admins pa where pa.user_id = auth.uid()

  );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.is_venue_member(p_venue_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    app_hidden.is_platform_admin()

    or exists (

      select 1

      from public.memberships m

      join public.venues v on v.id = p_venue_id

      where m.user_id = auth.uid()

        and (m.venue_id = p_venue_id or (m.venue_id is null and m.organization_id = v.organization_id))

    );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.log_incident_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  if new.status is distinct from old.status then

    insert into public.audit_log (organization_id, venue_id, actor_user_id, action, target_table, target_id, metadata)

    values (

      new.organization_id,

      new.venue_id,

      auth.uid(),

      'incident.status_changed',

      'incidents',

      new.id,

      jsonb_build_object('from', old.status, 'to', new.status)

    );

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.notify_staff_request_created()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  insert into public.notification_events (

    organization_id, venue_id, target_user_id, audience, kind, title, body, data

  ) values (

    new.organization_id,

    new.venue_id,

    null,

    'venue_managers',

    'staff_request',

    'New staff request',

    new.title,

    jsonb_build_object('origin', 'db', 'staff_request_id', new.id)

  );

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_checklist_completion_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

  v_venue_id uuid;

begin

  select organization_id, venue_id into v_org_id, v_venue_id

  from public.checklist_templates

  where id = new.template_id;



  if v_org_id is null then

    raise exception 'checklist template % does not exist', new.template_id;

  end if;



  new.organization_id := v_org_id;

  new.venue_id := v_venue_id;

  new.completed_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_checklist_template_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.created_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_document_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_event_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.created_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_incident_attachment_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

  v_venue_id uuid;

  v_expected_prefix text;

begin

  select organization_id, venue_id into v_org_id, v_venue_id

    from public.incidents

   where id = new.incident_id;



  if v_org_id is null then

    raise exception 'incident % does not exist', new.incident_id;

  end if;



  -- {organization_id}/{venue_id}/{incident_id}/...

  v_expected_prefix :=

    v_org_id::text || '/' || v_venue_id::text || '/' || new.incident_id::text || '/';

  if left(new.storage_path, length(v_expected_prefix)) <> v_expected_prefix then

    raise exception 'storage_path must be under %', v_expected_prefix;

  end if;



  new.organization_id := v_org_id;

  new.venue_id := v_venue_id;

  new.uploaded_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_incident_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.reported_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_inventory_item_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.updated_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_invite_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.invited_by := auth.uid();

  new.email := lower(trim(new.email));

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_notification_event_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  if new.organization_id is null and new.venue_id is not null then

    select organization_id into new.organization_id

    from public.venues

    where id = new.venue_id;

  end if;



  if new.organization_id is null then

    raise exception 'notification_events requires a valid venue_id or organization_id'

      using errcode = '23502';

  end if;



  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_payroll_connection_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_shift_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.created_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_shift_insight_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

  v_shift_venue_id uuid;

begin

  if new.venue_id is not null then

    select organization_id into v_org_id from public.venues where id = new.venue_id;

    if v_org_id is null then

      raise exception 'venue % does not exist', new.venue_id;

    end if;



    if new.shift_id is not null then

      select venue_id into v_shift_venue_id from public.shifts where id = new.shift_id;

      if v_shift_venue_id is null or v_shift_venue_id <> new.venue_id then

        raise exception 'shift % does not belong to venue %', new.shift_id, new.venue_id;

      end if;

    end if;

  elsif new.shift_id is not null then

    select venue_id, organization_id into new.venue_id, v_org_id

    from public.shifts

    where id = new.shift_id;



    if v_org_id is null then

      raise exception 'shift % does not exist', new.shift_id;

    end if;

  else

    raise exception 'either venue_id or shift_id is required';

  end if;



  new.organization_id := v_org_id;

  if new.created_by is null and auth.uid() is not null then

    new.created_by := auth.uid();

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_shift_swap_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

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

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_staff_request_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

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

$function$;

CREATE OR REPLACE FUNCTION app_hidden.prepare_task_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.created_by := auth.uid();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.shares_scope_with(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    app_hidden.is_platform_admin()

    or exists (

      select 1

      from public.memberships mine

      join public.memberships theirs

        on theirs.organization_id = mine.organization_id

       and (mine.venue_id is null or theirs.venue_id is null or mine.venue_id = theirs.venue_id)

      where mine.user_id = auth.uid()

        and theirs.user_id = p_user_id

    );

$function$;

CREATE OR REPLACE FUNCTION app_hidden.storage_path_conversation_id(object_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[3]);

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.storage_path_document_category(object_name text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_filename text;

  v_category text;

begin

  v_filename := (string_to_array(object_name, '/'))[3];

  if v_filename is null then

    return null;

  end if;

  v_category := split_part(v_filename, '--', 1);

  if v_category not in ('sop', 'manual', 'recipe', 'menu', 'training', 'form', 'other') then

    return null;

  end if;

  return v_category;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.storage_path_venue_id(object_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  return app_hidden.try_cast_uuid((string_to_array(object_name, '/'))[2]);

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sweep_account_deletion_jobs(p_batch_size integer DEFAULT 25)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r record;
  v_dispatched integer := 0;
begin
  update public.account_deletion_jobs
  set status = 'dead',
      last_error = coalesce(last_error, 'worker never reported a result'),
      updated_at = now()
  where status = 'processing'
    and attempts >= 10
    and updated_at < now() - interval '15 minutes';

  for r in
    select id
    from public.account_deletion_jobs
    where attempts < 10
      and (
        (status in ('pending', 'failed') and updated_at < now() - interval '10 minutes')
        or (status = 'processing' and updated_at < now() - interval '15 minutes')
      )
    order by created_at asc
    limit p_batch_size
    for update skip locked
  loop
    perform app_hidden.dispatch_account_deletion_job(r.id);
    v_dispatched := v_dispatched + 1;
  end loop;

  return v_dispatched;
end;
$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_checklist_item_venue_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_venue_id uuid;

begin

  select venue_id into v_venue_id from public.checklist_templates where id = new.template_id;

  if v_venue_id is null then

    raise exception 'checklist template % does not exist', new.template_id;

  end if;

  new.venue_id := v_venue_id;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_event_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_incident_resolution()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  new.updated_at := now();

  if new.status in ('resolved', 'closed') and old.status not in ('resolved', 'closed') then

    new.resolved_at := now();

    new.resolved_by := auth.uid();

  elsif new.status not in ('resolved', 'closed') then

    new.resolved_at := null;

    new.resolved_by := null;

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_inventory_item_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  -- Not re-stamped while an account deletion is clearing updated_by (it would put the
  -- departing user straight back, and block the final auth.users delete).
  if not app_hidden.account_deletion_in_progress() then
    new.updated_by := auth.uid();
  end if;
  new.updated_at := now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_payroll_connection_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_shift_insight_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_shift_swap_timestamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_shift_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_staff_request_timestamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  new.updated_at := now();

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_task_organization_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_org_id uuid;

begin

  select organization_id into v_org_id from public.venues where id = new.venue_id;

  if v_org_id is null then

    raise exception 'venue % does not exist', new.venue_id;

  end if;

  new.organization_id := v_org_id;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION app_hidden.sync_task_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

begin

  new.updated_at := now();

  if new.status = 'completed' and old.status is distinct from 'completed' then

    new.completed_at := now();

  elsif new.status <> 'completed' then

    new.completed_at := null;

  end if;

  return new;

end;

$function$;

CREATE OR REPLACE FUNCTION public.crm_pipeline_forecast(p_venue_id uuid)
 RETURNS TABLE(status text, lead_count bigint, raw_value_cents bigint, weighted_value_cents bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    l.status,

    count(*)::bigint as lead_count,

    coalesce(sum(l.estimated_value_cents), 0)::bigint as raw_value_cents,

    round(coalesce(sum(l.estimated_value_cents), 0) * (

      case l.status

        when 'new' then 0.05

        when 'contacted' then 0.15

        when 'qualified' then 0.3

        when 'proposal_sent' then 0.5

        when 'negotiating' then 0.7

        when 'won' then 1.0

        when 'lost' then 0

        when 'unqualified' then 0

        when 'on_hold' then 0.1

      end

    ))::bigint as weighted_value_cents

  from public.crm_leads l

  where l.venue_id = p_venue_id

    and l.deleted_at is null

    and app_hidden.has_venue_role(

      p_venue_id,

      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

    )

  group by l.status;

$function$;

CREATE OR REPLACE FUNCTION public.crm_source_roi(p_venue_id uuid)
 RETURNS TABLE(source text, lead_count bigint, pipeline_value_cents bigint, won_count bigint, won_value_cents bigint, lost_count bigint, win_rate numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    coalesce(l.source, '(unspecified)') as source,

    count(*)::bigint as lead_count,

    coalesce(sum(l.estimated_value_cents), 0)::bigint as pipeline_value_cents,

    count(*) filter (where l.status = 'won')::bigint as won_count,

    coalesce(sum(l.estimated_value_cents) filter (where l.status = 'won'), 0)::bigint as won_value_cents,

    count(*) filter (where l.status in ('lost', 'unqualified'))::bigint as lost_count,

    case when count(*) = 0 then 0

      else round(count(*) filter (where l.status = 'won')::numeric / count(*), 4)

    end as win_rate

  from public.crm_leads l

  where l.venue_id = p_venue_id

    and l.deleted_at is null

    and app_hidden.has_venue_role(

      p_venue_id,

      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

    )

  group by coalesce(l.source, '(unspecified)')

  order by won_value_cents desc;

$function$;

CREATE OR REPLACE FUNCTION public.crm_stale_leads(p_venue_id uuid, p_days integer DEFAULT 5)
 RETURNS TABLE(id uuid, full_name text, status text, last_activity_at timestamp with time zone, days_since_activity integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$

  select

    l.id,

    l.full_name,

    l.status,

    l.last_activity_at,

    floor(extract(epoch from (now() - coalesce(l.last_activity_at, l.created_at))) / 86400)::integer as days_since_activity

  from public.crm_leads l

  where l.venue_id = p_venue_id

    and l.deleted_at is null

    and l.status in ('new', 'contacted', 'qualified', 'proposal_sent', 'negotiating')

    and (l.last_activity_at is null or l.last_activity_at < now() - make_interval(days => greatest(1, least(60, p_days))))

    and app_hidden.has_venue_role(

      p_venue_id,

      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

    )

  order by coalesce(l.last_activity_at, l.created_at) asc

  limit 50;

$function$;

CREATE OR REPLACE FUNCTION public.render_email_template(p_template_id uuid, p_lead_id uuid DEFAULT NULL::uuid, p_beo_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(subject text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$

declare

  v_template record;

  v_venue record;

  v_lead record;

  v_beo record;

  v_vars jsonb := '{}'::jsonb;

  v_subject text;

  v_body text;

  v_key text;

begin

  select * into v_template from public.email_templates where id = p_template_id;

  if v_template.id is null then

    raise exception 'template % does not exist', p_template_id using errcode = '23503';

  end if;



  if not app_hidden.has_venue_role(

    v_template.venue_id,

    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]

  ) then

    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';

  end if;



  select name into v_venue from public.venues where id = v_template.venue_id;

  v_vars := jsonb_build_object('venue.name', coalesce(v_venue.name, ''));



  if p_lead_id is not null then

    select * into v_lead from public.crm_leads where id = p_lead_id and venue_id = v_template.venue_id;

    if v_lead.id is not null then

      v_vars := v_vars || jsonb_build_object(

        'lead.name', coalesce(v_lead.full_name, ''),

        'lead.firstName', coalesce(split_part(v_lead.full_name, ' ', 1), ''),

        'lead.email', coalesce(v_lead.email, ''),

        'lead.phone', coalesce(v_lead.phone, ''),

        'lead.company', coalesce(v_lead.company, ''),

        'lead.source', coalesce(v_lead.source, '')

      );

    end if;

  end if;



  if p_beo_id is not null then

    select * into v_beo from public.crm_beos where id = p_beo_id and venue_id = v_template.venue_id;

    if v_beo.id is not null then

      v_vars := v_vars || jsonb_build_object(

        'event.name', coalesce(v_beo.event_name, ''),

        'event.date', coalesce(to_char(v_beo.event_date, 'FMMonth FMDD, YYYY'), ''),

        'event.space', coalesce(v_beo.venue_space, ''),

        'event.guestCount', coalesce(v_beo.guest_count::text, '')

      );

    end if;

  end if;



  v_subject := v_template.subject;

  v_body := v_template.body;

  for v_key in select jsonb_object_keys(v_vars) loop

    v_subject := replace(v_subject, '{{' || v_key || '}}', v_vars ->> v_key);

    v_body := replace(v_body, '{{' || v_key || '}}', v_vars ->> v_key);

  end loop;



  return query select v_subject, v_body;

end;

$function$;

