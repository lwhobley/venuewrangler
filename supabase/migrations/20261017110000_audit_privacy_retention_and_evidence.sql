-- Security-audit remediation (SECURITY_AUDIT_2026-10-17), part 2: privacy, retention, evidence.
--
--   P-03  guest/lead erasure (erase_guest) and time-based purges for guest PII, POS payloads,
--         stale invites, notifications and raw punch GPS.
--   P-04  employee deletion keeps only what wage law requires (restricted legal-hold table),
--         and scrubs the user's identity and GPS from the audit trail.
--   D-04  deleted incident evidence is queued for Storage deletion; deletion jobs survive
--         org/venue deletion (no FK to rows that are being deleted).
--   R-04  silent-failure paths are visible: warnings plus public.ops_health_report().
--   P-06  raw POS webhook payloads are no longer readable by staff clients.
--   D-06  length caps on free-text columns; cap on push tokens per user.

-- -----------------------------------------------------------------------------
-- 1. Restricted legal-hold table for wage-law records (FLSA 516.2: name, rate, hire data).
-- -----------------------------------------------------------------------------
create table if not exists public.retained_wage_profiles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  venue_id uuid,
  anonymized_user_label text not null,
  legal_name text,
  employee_number text,
  job_title text,
  hire_date date,
  hourly_rate_cents integer,
  retention_reason text not null default 'wage_and_hour_recordkeeping',
  retained_at timestamptz not null default now()
);
create index if not exists retained_wage_profiles_retained_at_idx on public.retained_wage_profiles (retained_at);
alter table public.retained_wage_profiles enable row level security;
alter table public.retained_wage_profiles force row level security;
revoke all on public.retained_wage_profiles from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Storage deletion jobs must outlive the org/venue they describe (D-04).
-- -----------------------------------------------------------------------------
-- The after-delete triggers on documents/messages/incident_attachments insert a job while the
-- parent org or venue is itself being deleted, which a FK would reject (aborting the delete) or,
-- with ON DELETE CASCADE, silently drop the pending job. Both ids are plain references now.
alter table public.storage_deletion_jobs drop constraint if exists storage_deletion_jobs_organization_id_fkey;
alter table public.storage_deletion_jobs drop constraint if exists storage_deletion_jobs_venue_id_fkey;

create or replace function app_hidden.enqueue_incident_attachment_deletion()
returns trigger
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
  values (old.organization_id, old.venue_id, 'incident-evidence', old.storage_path);
  return old;
exception when others then
  -- A malformed legacy path must not block deleting the incident; surface it instead.
  raise warning 'could not queue storage deletion for incident attachment %: %', old.id, sqlerrm;
  return old;
end;
$$;

drop trigger if exists enqueue_incident_attachment_deletion on public.incident_attachments;
create trigger enqueue_incident_attachment_deletion
  after delete on public.incident_attachments
  for each row execute function app_hidden.enqueue_incident_attachment_deletion();

-- -----------------------------------------------------------------------------
-- 3. Retention-time bypasses for two guarded tables. Each is honoured only for a statement
--    that changes nothing but the columns being purged, and is set/reset around the purge.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.guard_pos_check_final_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.venue_id is distinct from old.venue_id then
    raise exception 'venue_id cannot be modified once set' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id cannot be modified once set' using errcode = '42501';
  end if;
  -- Retention purge: only guest PII / raw payload may change on a finished check.
  if coalesce(current_setting('app.pos_retention', true), '') = 'on'
     and (to_jsonb(new) - 'raw_payload' - 'guest_name' - 'updated_at')
         = (to_jsonb(old) - 'raw_payload' - 'guest_name' - 'updated_at') then
    return new;
  end if;
  if old.status = 'voided' or (old.status = 'closed' and new.status <> 'voided') then
    return old;
  end if;
  return new;
end;
$$;

-- Staff clients read POS checks without the raw webhook payload (it can carry customer data).
revoke select on public.pos_checks from authenticated;
grant select (
  id, organization_id, venue_id, pos_connection_id, provider, external_check_id, table_label,
  server_name, guest_name, guest_count, opened_at, closed_at, subtotal_cents, tax_cents,
  tip_cents, total_cents, status, menu_items, created_at, updated_at
) on public.pos_checks to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Guest / lead erasure (P-03).
-- -----------------------------------------------------------------------------
create or replace function public.erase_guest(p_guest_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_g public.guests;
  v_leads uuid[];
begin
  select * into v_g from public.guests where id = p_guest_id for update;
  if not found then
    raise exception 'guest not found' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_g.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- Reservations keep their operational facts but lose the person.
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

  perform set_config('app.pos_retention', 'on', true);
  update public.pos_checks
     set guest_name = null, raw_payload = null
   where venue_id = v_g.venue_id and lower(guest_name) = lower(v_g.full_name);
  perform set_config('app.pos_retention', 'off', true);

  delete from public.guests where id = v_g.id;

  perform app_hidden.audit_event(
    v_g.organization_id, v_g.venue_id, 'guest.erase', 'guests', v_g.id,
    jsonb_build_object('leads_anonymized', coalesce(array_length(v_leads, 1), 0))
  );
end;
$$;

revoke all on function public.erase_guest(uuid) from public, anon;
grant execute on function public.erase_guest(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Retention (P-03, P-08/F-19). Same signature as before; the extra purges are not counted.
-- -----------------------------------------------------------------------------
create or replace function app_hidden.run_retention_cleanup()
returns table (
  audit_log_deleted bigint,
  attestation_challenges_deleted bigint,
  retained_time_entries_deleted bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_audit bigint;
  v_audit_corrections bigint;
  v_challenges bigint;
  v_wage bigint;
  v_gps_days integer;
begin
  delete from public.audit_log
    where action not in ('time_entry.correct', 'time_entry.void')
      and created_at < now() - interval '365 days';
  get diagnostics v_audit = row_count;

  delete from public.audit_log
    where action in ('time_entry.correct', 'time_entry.void')
      and created_at < now() - interval '3 years';
  get diagnostics v_audit_corrections = row_count;
  v_audit := v_audit + v_audit_corrections;

  delete from public.attestation_challenges where expires_at < now() - interval '1 hour';
  get diagnostics v_challenges = row_count;

  delete from public.retained_time_entries
    where coalesce(clock_out_at, clock_in_at) < now() - interval '3 years';
  get diagnostics v_wage = row_count;

  delete from public.retained_wage_profiles where retained_at < now() - interval '3 years';

  -- Raw POS webhook payloads: operational need is short; the parsed columns remain.
  perform set_config('app.pos_retention', 'on', true);
  update public.pos_checks set raw_payload = null
    where raw_payload is not null and created_at < now() - interval '90 days';
  perform set_config('app.pos_retention', 'off', true);

  -- Guest PII on finished reservations is anonymized after 24 months.
  update public.reservations
     set guest_name = 'Guest', guest_phone = null, guest_email = null
   where status in ('completed', 'cancelled', 'no_show')
     and reservation_time < now() - interval '24 months'
     and (guest_phone is not null or guest_email is not null or guest_name <> 'Guest');

  -- Invites hold email addresses: drop resolved ones after 90 days, stale pending after 30.
  delete from public.invites
    where (status <> 'pending' and created_at < now() - interval '90 days')
       or (status = 'pending' and expires_at < now() - interval '30 days');

  delete from public.notification_events where created_at < now() - interval '180 days';

  delete from app_hidden.rate_limit_counters where window_start < now() - interval '2 days';

  -- Raw GPS of finished punches (verdicts and times are kept), per platform_settings.
  select s.gps_retention_days into v_gps_days from app_hidden.platform_settings s;
  if v_gps_days is not null then
    perform set_config('app.gps_purge', 'on', true);
    update public.time_entries
       set clock_in_lat = null, clock_in_lng = null, clock_in_accuracy_m = null,
           clock_out_lat = null, clock_out_lng = null, clock_out_accuracy_m = null
     where not is_open
       and clock_out_at < now() - make_interval(days => v_gps_days)
       and (clock_in_lat is not null or clock_out_lat is not null);
    perform set_config('app.gps_purge', 'off', true);
  end if;

  return query select v_audit, v_challenges, v_wage;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Visible failure for deletion dispatch + an ops health report (R-04).
-- -----------------------------------------------------------------------------
create or replace function app_hidden.dispatch_account_deletion_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
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
$$;

-- Poll this from monitoring (service role): any row with severity 'critical' or 'warning'
-- should page. An empty result means healthy.
create or replace function public.ops_health_report()
returns table (check_name text, severity text, detail text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count bigint;
begin
  select count(*) into v_count from public.account_deletion_jobs
  where status not in ('completed') and created_at < now() - interval '1 day';
  if v_count > 0 then
    return query select 'account_deletion_jobs_stuck'::text, 'critical'::text,
      v_count || ' account deletion job(s) older than 1 day are not completed (GDPR Art. 17: one month limit)';
  end if;

  select count(*) into v_count from public.storage_deletion_jobs
  where (status in ('failed', 'dead')) or (status in ('pending', 'processing') and created_at < now() - interval '1 day');
  if v_count > 0 then
    return query select 'storage_deletion_jobs_stuck'::text, 'warning'::text,
      v_count || ' storage deletion job(s) failed, dead or older than 1 day';
  end if;

  begin
    select count(*) into v_count from vault.decrypted_secrets
    where name in ('account_deletion_dispatch_url', 'account_deletion_dispatch_secret');
    if v_count < 2 then
      return query select 'account_deletion_vault_secrets_missing'::text, 'critical'::text,
        'vault secrets for account deletion dispatch are missing'::text;
    end if;
  exception when others then
    return query select 'vault_unavailable'::text, 'warning'::text, 'could not read vault secrets'::text;
  end;

  begin
    execute $q$select count(*) from cron.job_run_details d
               where d.status = 'failed' and d.start_time > now() - interval '1 day'$q$ into v_count;
    if v_count > 0 then
      return query select 'cron_job_failures'::text, 'warning'::text,
        v_count || ' pg_cron run(s) failed in the last 24h';
    end if;
  exception when others then
    null; -- pg_cron not installed (local/CI)
  end;
end;
$$;

revoke all on function public.ops_health_report() from public, anon, authenticated;
grant execute on function public.ops_health_report() to service_role;

-- -----------------------------------------------------------------------------
-- 7. Input bounds (D-06). NOT VALID: enforced for new/updated rows without scanning history.
-- -----------------------------------------------------------------------------
alter table public.messages add constraint messages_text_len_chk check (char_length(text) <= 4000) not valid;
alter table public.incidents add constraint incidents_description_len_chk check (char_length(description) <= 10000) not valid;
alter table public.crm_notes add constraint crm_notes_text_len_chk check (char_length(text) <= 5000) not valid;
alter table public.guests add constraint guests_notes_len_chk
  check (char_length(notes) <= 5000 and char_length(dietary_notes) <= 2000) not valid;
alter table public.reservations add constraint reservations_text_len_chk
  check (char_length(notes) <= 5000 and char_length(special_requests) <= 2000) not valid;

create or replace function app_hidden.cap_push_tokens_per_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.push_tokens t where t.user_id = new.user_id) >= 25 then
    -- Prefer recycling the stalest disabled token before refusing.
    delete from public.push_tokens where id = (
      select t.id from public.push_tokens t
      where t.user_id = new.user_id and not t.enabled
      order by t.last_seen_at nulls first limit 1
    );
    if (select count(*) from public.push_tokens t where t.user_id = new.user_id) >= 25 then
      raise exception 'push token limit reached' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists cap_push_tokens_per_user on public.push_tokens;
create trigger cap_push_tokens_per_user
  before insert on public.push_tokens
  for each row execute function app_hidden.cap_push_tokens_per_user();

-- Raw coordinates of finished punches are purged on a schedule (platform_settings.gps_retention_days),
-- so the clock-in location columns must be nullable once a punch is closed. Open punches still
-- require a full location fix.
alter table public.time_entries
  alter column clock_in_lat drop not null,
  alter column clock_in_lng drop not null,
  alter column clock_in_accuracy_m drop not null;
alter table public.time_entries drop constraint if exists time_entries_open_has_location_chk;
alter table public.time_entries add constraint time_entries_open_has_location_chk
  check (not is_open or (clock_in_lat is not null and clock_in_lng is not null and clock_in_accuracy_m is not null));

-- -----------------------------------------------------------------------------
-- 8. Time-entry guard: allow the GPS retention purge (and nothing else) through.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_hidden.enforce_time_entry_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if coalesce(current_setting('app.gps_purge', true), '') = 'on'
     and (to_jsonb(new) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at')
         = (to_jsonb(old) - 'clock_in_lat' - 'clock_in_lng' - 'clock_in_accuracy_m' - 'clock_out_lat' - 'clock_out_lng' - 'clock_out_accuracy_m' - 'updated_at') then
    return new;
  end if;

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
$function$;


-- -----------------------------------------------------------------------------
-- 9. Account deletion: wage-law legal hold + identity scrub of audit metadata.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_account_deletion_impl(p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_label text;
  v_sole_owner_orgs integer;
  v_photo record;
  v_job_id uuid;
begin
  if v_uid is null then
    raise exception 'Must be signed in to delete your account' using errcode = '42501';
  end if;

  -- Block if this account is the only organization_owner of any organization: deleting it
  -- would leave that organization with no owner at all. They must add another
  -- organization_owner membership before they can self-delete.
  select count(*) into v_sole_owner_orgs
  from public.memberships m1
  where m1.user_id = v_uid
    and m1.role = 'organization_owner'
    and not exists (
      select 1 from public.memberships m2
      where m2.organization_id = m1.organization_id
        and m2.role = 'organization_owner'
        and m2.user_id <> v_uid
    );

  if v_sole_owner_orgs > 0 then
    raise exception 'You are the only owner of % organization(s). Add another organization owner before deleting your account.', v_sole_owner_orgs
      using errcode = '42501';
  end if;

  v_label := 'deleted_user_' || v_uid::text;

  -- Lets the client-facing guard triggers stand down for the rest of this transaction only
  -- (see app_hidden.account_deletion_in_progress); reset explicitly before returning.
  perform set_config('app.account_deletion', 'on', true);

  -- Preserve wage history (FLSA 516.2) before it would otherwise cascade away.
  insert into public.retained_time_entries (
    original_time_entry_id, organization_id, venue_id, anonymized_user_label,
    shift_id, clock_in_at, clock_out_at, breaks, location_anomaly
  )
  select
    te.id, te.organization_id, te.venue_id, v_label,
    te.shift_id, te.clock_in_at, te.clock_out_at, te.breaks, te.location_anomaly
  from public.time_entries te
  where te.user_id = v_uid;

  -- Wage-law legal hold (FLSA 516.2): the few HR fields employers must keep, in a restricted
  -- table with a 3-year purge, labelled with the same pseudonym as the retained punches.
  insert into public.retained_wage_profiles (
    organization_id, venue_id, anonymized_user_label, legal_name, employee_number, job_title,
    hire_date, hourly_rate_cents
  )
  select v.organization_id, hp.venue_id, v_label, hp.legal_name, hp.employee_number, hp.job_title,
         hp.hire_date, hp.hourly_rate_cents
  from public.employee_hr_profiles hp
  join public.venues v on v.id = hp.venue_id
  where hp.user_id = v_uid and hp.hourly_rate_cents is not null;

  -- Queue the actual profile photo file(s) for deletion from Storage before dropping the
  -- row that names them.
  for v_photo in
    select v.organization_id, sp.venue_id, sp.storage_path
    from public.staff_photos sp
    join public.venues v on v.id = sp.venue_id
    where sp.user_id = v_uid
  loop
    insert into public.storage_deletion_jobs (organization_id, venue_id, bucket_id, object_path)
    values (v_photo.organization_id, v_photo.venue_id, 'profile-photos', v_photo.storage_path);
  end loop;

  -- Anonymize attribution on records that must survive this account's departure.
  -- audit_log is append-only and retained independently (see data-retention-disposal-
  -- policy.md section 3) - the row itself stays, only who-did-it is forgotten.
  update public.audit_log set actor_user_id = null where actor_user_id = v_uid;
  update public.organizations set created_by = null where created_by = v_uid;
  update public.venues set created_by = null where created_by = v_uid;
  update public.memberships set created_by = null where created_by = v_uid;
  update public.platform_admins set created_by = null where created_by = v_uid;
  update public.operational_tasks set assigned_to = null where assigned_to = v_uid;
  update public.operational_tasks set created_by = null where created_by = v_uid;
  update public.checklist_templates set created_by = null where created_by = v_uid;
  update public.checklist_completions set completed_by = null where completed_by = v_uid;
  update public.incidents set reported_by = null where reported_by = v_uid;
  update public.incidents set resolved_by = null where resolved_by = v_uid;
  update public.incident_attachments set uploaded_by = null where uploaded_by = v_uid;
  update public.ai_usage_events set user_id = null where user_id = v_uid;
  update public.invites set invited_by = null where invited_by = v_uid;
  update public.inventory_items set updated_by = null where updated_by = v_uid;
  update public.shifts set staff_id = null where staff_id = v_uid;
  update public.shifts set created_by = null where created_by = v_uid;
  update public.payroll_connections set connected_by = null where connected_by = v_uid;
  update public.events set created_by = null where created_by = v_uid;
  update public.documents set uploaded_by = null where uploaded_by = v_uid;
  update public.pos_schedule_versions set published_by = null where published_by = v_uid;
  update public.pos_audit_events set actor_id = null where actor_id = v_uid;

  -- ON DELETE SET NULL columns: left to the final auth.users delete they'd run through the
  -- same guard triggers with auth.uid() null (and no flag), so clear them here instead.
  update public.staff_requests set reviewer_id = null where reviewer_id = v_uid;
  update public.shift_insights set created_by = null where created_by = v_uid;
  update public.crm_activity_log set actor_id = null where actor_id = v_uid;
  update public.crm_beos set assigned_rep_id = null where assigned_rep_id = v_uid;
  update public.crm_leads set assigned_to = null where assigned_to = v_uid;
  update public.crm_notes set author_id = null where author_id = v_uid;
  update public.messages set sender_id = null where sender_id = v_uid;
  update public.reservations set assigned_to = null where assigned_to = v_uid;

  -- Workflow rows that are this user's own in-flight requests, not records anyone else needs
  -- attributable (unlike audit_log/time_entries above) - removed outright rather than
  -- anonymized. shift_swaps.requested_by and pos_employee_mappings.staff_id are both NOT
  -- NULL with no ON DELETE action, so they can't simply be set to null.
  delete from public.shift_swaps where requested_by = v_uid;
  update public.shift_swaps set offered_to = null where offered_to = v_uid;
  update public.shift_swaps set accepted_by = null where accepted_by = v_uid;
  delete from public.pos_employee_mappings where staff_id = v_uid;
  delete from public.staff_requests where user_id = v_uid;

  -- Per-device/per-user delivery state: gone immediately, so a deleted account stops getting
  -- pushed to rather than waiting for the async auth.users delete.
  delete from public.push_tokens where user_id = v_uid;
  delete from public.device_attestations where user_id = v_uid;
  delete from public.attestation_challenges where user_id = v_uid;
  delete from public.notification_events where target_user_id = v_uid;
  delete from public.conversation_members where user_id = v_uid;
  delete from public.conversation_reads where user_id = v_uid;

  -- Forget who this was in the audit trail: punch corrections/voids keep their (GPS-free) record
  -- but lose the user id; membership/invite events naming the user lose it too.
  update public.audit_log
     set metadata = metadata
       || case when metadata ? 'before' then jsonb_build_object('before', (metadata -> 'before') - 'user_id') else '{}'::jsonb end
       || case when metadata ? 'after' then jsonb_build_object('after', (metadata -> 'after') - 'user_id') else '{}'::jsonb end
   where action in ('time_entry.correct', 'time_entry.void')
     and (
       metadata -> 'before' ->> 'user_id' = v_uid::text
       or target_id in (select te.id from public.time_entries te where te.user_id = v_uid)
     );
  update public.audit_log set metadata = metadata - 'user_id' - 'new_owner_user_id'
   where (metadata ->> 'user_id' = v_uid::text or metadata ->> 'new_owner_user_id' = v_uid::text);

  -- Drop this account's own memberships, time entries, HR profile, photos and profile now
  -- (would cascade from the eventual auth.users delete anyway; doing it here means the
  -- account is already functionally gone even before the async job runs).
  delete from public.time_entries where user_id = v_uid;
  delete from public.memberships where user_id = v_uid;
  delete from public.employee_hr_profiles where user_id = v_uid;
  delete from public.staff_photos where user_id = v_uid;
  delete from public.profiles where id = v_uid;

  insert into public.audit_log (actor_user_id, action, target_table, target_id, metadata)
  values (null, 'account.delete_requested', 'auth.users', v_uid, jsonb_build_object('reason', p_reason));

  -- One live job per user: a retry after a dropped response reuses it.
  select id into v_job_id
  from public.account_deletion_jobs
  where user_id = v_uid and status not in ('completed', 'dead')
  order by created_at
  limit 1;

  if v_job_id is null then
    insert into public.account_deletion_jobs (user_id, requested_reason)
    values (v_uid, p_reason)
    returning id into v_job_id;
  end if;

  perform set_config('app.account_deletion', 'off', true);

  perform app_hidden.dispatch_account_deletion_job(v_job_id);

  return v_job_id;
end;
$function$;

