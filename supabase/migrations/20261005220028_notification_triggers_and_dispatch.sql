-- Nothing ever called notifications-send, so no business event produced a notification (in-app
-- or push). This adds database triggers that write notification_events for the two events the
-- app's notification kinds already model, and a pg_net hook that fans an event out to devices
-- through the internal notifications-dispatch Edge Function.
--
-- The dispatch hook reads its target URL and shared secret from Vault
-- (`push_dispatch_url`, `push_dispatch_secret`). Until both exist it does nothing, so applying
-- this migration alone never breaks a write — in-app notifications work immediately and push
-- starts the moment the secrets are provisioned (see docs/migration/push-dispatch-setup.md).

-- pg_net is not available at all in a vanilla local Postgres (no contrib package); guarded
-- the same way pg_cron is in storage_deletion_worker_and_schedule.sql — local CI
-- verification must not depend on a platform-managed extension. Safe to skip here: every
-- net.http_post call below already runs inside its own exception handler (a push failure
-- must never roll back the business write that triggered it), so a missing pg_net just
-- means that handler fires instead.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
exception when others then
  null;
end;
$$;

create or replace function app_hidden.dispatch_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function app_hidden.dispatch_notification_push() from public, anon, authenticated;

-- Only rows the triggers below create are dispatched here; events inserted by
-- notifications-send are delivered by that function itself (no double push).
create trigger trg_notification_events_push
  after insert on public.notification_events
  for each row
  when (new.data ->> 'origin' = 'db')
  execute function app_hidden.dispatch_notification_push();

create or replace function app_hidden.notify_shift_assigned()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tz text;
begin
  if new.staff_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.staff_id is not distinct from old.staff_id then
    return new;
  end if;
  -- Don't notify someone about a shift they scheduled for themselves.
  if new.created_by is not distinct from new.staff_id then
    return new;
  end if;

  select timezone into v_tz from public.venues where id = new.venue_id;

  insert into public.notification_events (
    organization_id, venue_id, target_user_id, audience, kind, title, body, data
  ) values (
    new.organization_id,
    new.venue_id,
    new.staff_id,
    'user',
    'shift_assigned',
    'New shift scheduled',
    coalesce(new.role_label || ' · ', '') ||
      to_char(new.start_time at time zone coalesce(v_tz, 'UTC'), 'Dy Mon DD, HH12:MI AM'),
    jsonb_build_object('origin', 'db', 'shift_id', new.id)
  );
  return new;
end;
$$;

revoke execute on function app_hidden.notify_shift_assigned() from public, anon, authenticated;

create trigger trg_shifts_notify_assigned
  after insert or update of staff_id on public.shifts
  for each row execute function app_hidden.notify_shift_assigned();

create or replace function app_hidden.notify_staff_request_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function app_hidden.notify_staff_request_created() from public, anon, authenticated;

create trigger trg_staff_requests_notify_created
  after insert on public.staff_requests
  for each row execute function app_hidden.notify_staff_request_created();
