-- Launch review U2: staff now reach the Requests screen (time off, drop a shift, pick up an open
-- shift). RLS already limits staff to creating and reading their own requests and managers to
-- reviewing them; this tightens what a request may point at and how approval assigns shifts:
--   * a drop request must name one of the requester's own live shifts, a pick-up request an
--     open one, so a manager is never asked to approve something that cannot apply;
--   * approving a pick-up refuses to double-book the requester unless the manager overrides it
--     through public.review_staff_request(..., p_allow_overlap => true);
--   * the requester hears back when a manager approves or denies.

create or replace function app_hidden.validate_staff_request_shift()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shift public.shifts%rowtype;
begin
  if new.kind not in ('drop_shift', 'open_shift', 'add_shift') then
    return new;
  end if;
  if new.requested_shift_id is null then
    raise exception 'choose the shift for this request' using errcode = '22023';
  end if;
  select * into v_shift from public.shifts
   where id = new.requested_shift_id and venue_id = new.venue_id;
  if not found or v_shift.status <> 'scheduled' then
    raise exception 'that shift is no longer on the schedule' using errcode = '22023';
  end if;
  if new.kind in ('drop_shift', 'open_shift') and v_shift.staff_id is distinct from new.user_id then
    raise exception 'you can only ask to drop your own shift' using errcode = '42501';
  end if;
  if new.kind = 'add_shift' and v_shift.staff_id is not null then
    raise exception 'that shift is no longer open' using errcode = '22023';
  end if;
  return new;
end;
$$;

revoke all on function app_hidden.validate_staff_request_shift() from public, anon, authenticated;

-- Runs after prepare_staff_request_insert (alphabetical), so user_id is already auth.uid().
create trigger zz_validate_staff_request_shift
  before insert on public.staff_requests
  for each row execute function app_hidden.validate_staff_request_shift();

create or replace function app_hidden.apply_approved_staff_request()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved'
     and new.kind in ('drop_shift', 'open_shift', 'add_shift') then
    if new.requested_shift_id is null then
      raise exception 'choose a shift before approving this request'
        using errcode = '22023';
    end if;
    if new.kind in ('drop_shift', 'open_shift') then
      update public.shifts set staff_id = null
        where id = new.requested_shift_id and venue_id = new.venue_id
          and staff_id = new.user_id;
    else
      perform app_hidden.assert_no_shift_overlap(new.user_id, new.requested_shift_id);
      update public.shifts set staff_id = new.user_id, status = 'scheduled'
        where id = new.requested_shift_id and venue_id = new.venue_id
          and staff_id is null;
    end if;
    if not found then
      raise exception 'the requested shift changed; review the schedule and request again'
        using errcode = '40001';
    end if;
  end if;
  return new;
end;
$$;

-- Review with an explicit double-booking override. Runs as the caller, so RLS and
-- enforce_staff_request_update still decide whether they may review this request at all.
create or replace function public.review_staff_request(
  p_request_id uuid,
  p_status text,
  p_response_notes text default null,
  p_allow_overlap boolean default false
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_status not in ('approved', 'denied') then
    raise exception 'a review must approve or deny' using errcode = '22023';
  end if;
  perform set_config('app.allow_shift_overlap', case when p_allow_overlap then 'on' else '' end, true);
  update public.staff_requests
    set status = p_status,
        response_notes = coalesce(nullif(trim(p_response_notes), ''), response_notes)
    where id = p_request_id;
  if not found then
    raise exception 'request not found or not yours to review' using errcode = '42501';
  end if;
  perform set_config('app.allow_shift_overlap', '', true);
end;
$$;

revoke all on function public.review_staff_request(uuid, text, text, boolean) from public, anon;
grant execute on function public.review_staff_request(uuid, text, text, boolean) to authenticated;

create or replace function app_hidden.notify_staff_request_reviewed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status not in ('approved', 'denied') or new.status is not distinct from old.status then
    return new;
  end if;
  insert into public.notification_events (
    organization_id, venue_id, target_user_id, audience, kind, title, body, data
  ) values (
    new.organization_id, new.venue_id, new.user_id, 'user', 'staff_request',
    case new.status when 'approved' then 'Request approved' else 'Request denied' end,
    new.title || coalesce(' — ' || nullif(trim(new.response_notes), ''), ''),
    jsonb_build_object('origin', 'db', 'staff_request_id', new.id)
  );
  return new;
end;
$$;

revoke all on function app_hidden.notify_staff_request_reviewed() from public, anon, authenticated;

create trigger trg_staff_requests_notify_reviewed
  after update of status on public.staff_requests
  for each row execute function app_hidden.notify_staff_request_reviewed();
