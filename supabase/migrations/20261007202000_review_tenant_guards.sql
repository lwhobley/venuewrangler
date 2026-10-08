-- Close cross-venue update paths even when a caller manages another workspace.
create or replace function app_hidden.guard_review_row_update()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := to_jsonb(old);
begin
  if v_new->>'organization_id' is distinct from v_old->>'organization_id'
     or v_new->>'venue_id' is distinct from v_old->>'venue_id' then
    raise exception 'row ownership cannot be changed' using errcode = '42501';
  end if;
  if tg_table_name = 'shift_swaps' then
    if v_new->>'shift_id' is distinct from v_old->>'shift_id' then
      raise exception 'swap shift cannot be changed' using errcode = '42501';
    end if;
    if v_new->>'status' = 'accepted' and v_old->>'status' is distinct from 'accepted' then
      if v_new->>'accepted_by' is null or not exists (
        select 1 from public.memberships m
        where m.user_id = (v_new->>'accepted_by')::uuid
          and m.organization_id = (v_old->>'organization_id')::uuid
          and (m.venue_id = (v_old->>'venue_id')::uuid or m.venue_id is null)
      ) then
        raise exception 'swap accepter must belong to the shift venue'
          using errcode = '42501';
      end if;
    end if;
  end if;
  if tg_table_name = 'time_entries'
     and (v_new->>'location_anomaly' is distinct from v_old->>'location_anomaly'
          or v_new->>'shift_id' is distinct from v_old->>'shift_id')
     and coalesce(current_setting('app.time_entry_correction', true), '') <> 'on' then
    raise exception 'punch integrity fields require a manager correction' using errcode = '42501';
  end if;
  return new;
end;
$$;
-- Approval must either perform its shift change or fail. Older requests may
-- have no shift id, and a shift may change while a manager reviews it.
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

create trigger guard_review_row_update before update on public.shift_swaps
  for each row execute function app_hidden.guard_review_row_update();
create trigger guard_review_row_update before update on public.operational_tasks
  for each row execute function app_hidden.guard_review_row_update();
create trigger guard_review_row_update before update on public.incidents
  for each row execute function app_hidden.guard_review_row_update();
create trigger guard_review_row_update before update on public.time_entries
  for each row execute function app_hidden.guard_review_row_update();

create or replace function app_hidden.guard_checklist_scope()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'checklist_templates' then
    if new.organization_id is distinct from old.organization_id
       or new.venue_id is distinct from old.venue_id then
      raise exception 'checklist ownership cannot be changed' using errcode = '42501';
    end if;
  else
    if new.template_id is distinct from old.template_id
       or new.venue_id is distinct from old.venue_id then
      raise exception 'checklist item ownership cannot be changed' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger guard_checklist_template_scope before update on public.checklist_templates
  for each row execute function app_hidden.guard_checklist_scope();
create trigger guard_checklist_item_scope before update on public.checklist_template_items
  for each row execute function app_hidden.guard_checklist_scope();

create or replace function app_hidden.guard_duplicate_pending_swap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() is distinct from
     (select staff_id from public.shifts where id = new.shift_id) then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('swap:' || new.shift_id::text, 0));
  if exists (select 1 from public.shift_swaps
    where shift_id = new.shift_id and status = 'pending') then
    raise exception 'a pending swap already exists for this shift'
      using errcode = '23505';
  end if;
  return new;
end;
$$;
create trigger guard_duplicate_pending_swap before insert on public.shift_swaps
  for each row execute function app_hidden.guard_duplicate_pending_swap();

create or replace function app_hidden.notify_shift_assigned()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_tz text;
begin
  if new.staff_id is null then return new; end if;
  if tg_op = 'UPDATE' then
    if new.staff_id is not distinct from old.staff_id then
      return new;
    end if;
  end if;
  if new.created_by is not distinct from new.staff_id then return new; end if;
  select timezone into v_tz from public.venues where id = new.venue_id;
  if v_tz is null or not exists (
    select 1 from pg_timezone_names where name = v_tz
  ) then
    v_tz := 'UTC';
  end if;
  insert into public.notification_events (
    organization_id, venue_id, target_user_id, audience, kind, title, body, data
  ) values (
    new.organization_id, new.venue_id, new.staff_id, 'user',
    'shift_assigned', 'New shift scheduled',
    coalesce(new.role_label || ' · ', '') ||
      to_char(new.start_time at time zone v_tz, 'Dy Mon DD, HH12:MI AM') ||
      case when v_tz = 'UTC' then ' UTC' else '' end,
    jsonb_build_object('origin', 'db', 'shift_id', new.id)
  );
  return new;
end;
$$;

create or replace function app_hidden.apply_accepted_shift_swap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
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

-- A stale editor must not report that its submitted entries were applied after
-- another device completed the count. Lock before checking so the check and
-- the existing save function run in one transaction.
alter function public.inventory_save_count(uuid,jsonb,boolean,boolean)
  rename to inventory_save_count_impl;
revoke all on function public.inventory_save_count_impl(uuid,jsonb,boolean,boolean)
  from public, anon, authenticated;
create function public.inventory_save_count(
  p_count uuid, p_values jsonb default '[]', p_complete boolean default false,
  p_cancel boolean default false
) returns void language plpgsql security definer set search_path = '' as $$
declare v_count public.inventory_counts;
begin
  select * into v_count from public.inventory_counts where id = p_count;
  perform app_hidden.inventory_assert_manager(v_count.venue_id);
  perform pg_advisory_xact_lock(hashtextextended(v_count.venue_id::text,0));
  select * into v_count from public.inventory_counts where id = p_count for update;
  if v_count.status in ('completed', 'cancelled') then
    raise exception 'This count is already closed; refresh before saving'
      using errcode = '22023';
  end if;
  perform public.inventory_save_count_impl(p_count,p_values,p_complete,p_cancel);
end;
$$;
revoke all on function public.inventory_save_count(uuid,jsonb,boolean,boolean)
  from public, anon;
grant execute on function public.inventory_save_count(uuid,jsonb,boolean,boolean)
  to authenticated;

-- The assignment row and its linked reservation must belong to the same venue as
-- the table. This runs on direct writes as well as the security-definer RPC.
create or replace function app_hidden.guard_floor_assignment_scope()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_venue_id uuid;
  v_org_id uuid;
begin
  select venue_id, organization_id into v_venue_id, v_org_id
    from public.floor_tables where id = new.table_id;
  if v_venue_id is null then
    raise exception 'invalid floor table' using errcode = '23503';
  end if;
  if auth.uid() is not null and not app_hidden.is_venue_member(v_venue_id) then
    raise exception 'floor table belongs to another venue' using errcode = '42501';
  end if;
  if new.reservation_id is not null and not exists (
    select 1 from public.reservations
    where id = new.reservation_id and venue_id = v_venue_id
  ) then
    raise exception 'reservation belongs to another venue' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if new.table_id is distinct from old.table_id
       or new.venue_id is distinct from old.venue_id
       or new.organization_id is distinct from old.organization_id then
      raise exception 'assignment ownership cannot be changed' using errcode = '42501';
    end if;
  end if;
  new.venue_id := v_venue_id;
  new.organization_id := v_org_id;
  return new;
end;
$$;

create trigger guard_floor_assignment_scope
  before insert or update on public.floor_table_assignments
  for each row execute function app_hidden.guard_floor_assignment_scope();

-- Conversation membership and metadata are managed by trusted functions and
-- message triggers. Direct client writes allow joining a private DM.
revoke insert on public.conversation_members from authenticated;
revoke insert, update on public.conversations from authenticated;

create or replace function app_hidden.guard_conversation_member_scope()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_conversation record;
begin
  select venue_id, organization_id into v_conversation
    from public.conversations where id = new.conversation_id;
  if not found then
    raise exception 'conversation does not exist' using errcode = '23503';
  end if;
  if not exists (
    select 1 from public.memberships m
    where m.user_id = new.user_id
      and m.organization_id = v_conversation.organization_id
      and (m.venue_id = v_conversation.venue_id or m.venue_id is null)
  ) then
    raise exception 'conversation member belongs to another venue'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_conversation_member_scope
  before insert on public.conversation_members
  for each row execute function app_hidden.guard_conversation_member_scope();

-- Schedule participants need names even when they cannot manage the roster.
create or replace function public.venue_schedule_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'Not allowed to view this schedule roster' using errcode = '42501';
  end if;
  return query
    select m.user_id, m.role, p.display_name
    from public.memberships m
    left join public.profiles p on p.id = m.user_id
    where m.venue_id = p_venue_id
    order by p.display_name nulls last, m.user_id;
end;
$$;
revoke all on function public.venue_schedule_roster(uuid) from public, anon;
grant execute on function public.venue_schedule_roster(uuid) to authenticated;

-- A message may only reference an object uploaded by its sender into that
-- conversation. This prevents deletion of a different member's object through
-- the privileged attachment cleanup trigger.
create or replace function app_hidden.guard_message_attachment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_conversation record;
begin
  if new.attachment_path is null or auth.uid() is null then
    return new;
  end if;
  select organization_id, venue_id into v_conversation
    from public.conversations where id = new.conversation_id;
  if not found
     or new.attachment_path !~* ('^' || v_conversation.organization_id::text || '/'
       || v_conversation.venue_id::text || '/' || new.conversation_id::text
       || '/[a-zA-Z0-9_.-]+$')
     or not exists (
       select 1 from storage.objects o
       where o.bucket_id = 'chat' and o.name = new.attachment_path
         and coalesce(to_jsonb(o)->>'owner_id', to_jsonb(o)->>'owner') = auth.uid()::text
     ) then
    raise exception 'attachment does not belong to sender and conversation'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger guard_message_attachment before insert on public.messages
  for each row execute function app_hidden.guard_message_attachment();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public'
        and tablename = 'messages') then
      alter publication supabase_realtime add table public.messages;
    end if;
  end if;
end;
$$;

-- All-staff channels are readable and writable by venue members without an
-- explicit conversation_members row; keep the derive trigger in sync with RLS.
create or replace function app_hidden.messages_derive_and_touch()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_conv_venue_id uuid;
  v_conv_org_id uuid;
  v_conv_type text;
begin
  if tg_op = 'INSERT' then
    if new.conversation_id is null and auth.uid() is not null then
      raise exception 'not authorized to post in this conversation'
        using errcode = '42501';
    end if;
    select venue_id, organization_id, type
      into v_conv_venue_id, v_conv_org_id, v_conv_type
      from public.conversations where id = new.conversation_id;
    if v_conv_venue_id is null then
      raise exception 'invalid_conversation_id: conversation does not exist'
        using errcode = '23503';
    end if;
    if auth.uid() is not null
       and not (app_hidden.is_conversation_member(new.conversation_id)
         or (v_conv_type = 'all_staff'
           and app_hidden.is_venue_member(v_conv_venue_id))) then
      raise exception 'not authorized to post in this conversation'
        using errcode = '42501';
    end if;
    new.venue_id := v_conv_venue_id;
    new.organization_id := v_conv_org_id;
    new.created_at := now();
    new.updated_at := now();
    update public.conversations
      set last_message_at = now(), last_message_text = coalesce(new.text, '[Attachment]'),
          updated_at = now()
      where id = new.conversation_id;
    return new;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- Lead and BEO links remain within the row's venue on every update.
create or replace function app_hidden.guard_crm_links()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := to_jsonb(new);
begin
  if v_new->>'lead_id' is not null and not exists (
    select 1 from public.crm_leads
    where id = (v_new->>'lead_id')::uuid and venue_id = (v_new->>'venue_id')::uuid
  ) then
    raise exception 'lead belongs to another venue' using errcode = '23503';
  end if;
  if tg_table_name = 'crm_contracts' and v_new->>'beo_id' is not null and not exists (
    select 1 from public.crm_beos
    where id = (v_new->>'beo_id')::uuid and venue_id = (v_new->>'venue_id')::uuid
  ) then
    raise exception 'BEO belongs to another venue' using errcode = '23503';
  end if;
  return new;
end;
$$;

create trigger guard_crm_links before insert or update on public.crm_beos
  for each row execute function app_hidden.guard_crm_links();
create trigger guard_crm_links before insert or update on public.crm_contracts
  for each row execute function app_hidden.guard_crm_links();

-- Treat event_date as the chosen start timestamp and recheck the full four-hour
-- hold whenever a confirmed BEO moves. Direct confirmed inserts must also
-- create their hold. Serialize BEO confirmations within a venue.
create or replace function app_hidden.crm_beos_sync_reservation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_existing uuid;
  v_guest_name text;
  v_guest_phone text;
  v_guest_email text;
  v_sync boolean := false;
begin
  if new.status = 'confirmed' then
    if new.event_date is null then
      raise exception 'choose an event start time before confirming the BEO'
        using errcode = '22023';
    end if;
    if tg_op = 'INSERT' then
      v_sync := true;
    else
      v_sync := old.status is distinct from 'confirmed'
        or new.event_date is distinct from old.event_date
        or new.guest_count is distinct from old.guest_count
        or new.venue_space is distinct from old.venue_space
        or new.lead_id is distinct from old.lead_id;
    end if;
  end if;
  if v_sync then
    perform pg_advisory_xact_lock(hashtextextended('beo:' || new.venue_id::text, 0));
    select id into v_existing from public.reservations where beo_id = new.id;
    if exists (
      select 1 from public.reservations r
      where r.venue_id = new.venue_id
        and r.status not in ('cancelled', 'no_show')
        and r.beo_id is distinct from new.id
        and r.reservation_time < new.event_date + interval '240 minutes'
        and r.reservation_time + make_interval(mins => r.duration_minutes)
          > new.event_date
    ) then
      raise exception 'reservation_hold_conflict: the requested event window is already held'
        using errcode = '23505';
    end if;
    if new.lead_id is not null then
      select full_name, phone, email
        into v_guest_name, v_guest_phone, v_guest_email
        from public.crm_leads where id = new.lead_id and venue_id = new.venue_id;
    end if;
    if v_existing is null then
      insert into public.reservations (
        venue_id, beo_id, guest_name, guest_phone, guest_email, party_size,
        reservation_time, duration_minutes, source, status, notes
      ) values (
        new.venue_id, new.id, coalesce(v_guest_name, new.event_name),
        v_guest_phone, v_guest_email, coalesce(new.guest_count, 1),
        new.event_date, 240, 'private_event', 'confirmed',
        nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), '')
      );
    else
      update public.reservations set
        reservation_time = new.event_date, duration_minutes = 240,
        party_size = coalesce(new.guest_count, party_size),
        guest_name = coalesce(v_guest_name, guest_name),
        guest_phone = coalesce(v_guest_phone, guest_phone),
        guest_email = coalesce(v_guest_email, guest_email),
        status = 'confirmed',
        notes = nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), ''),
        updated_at = now()
      where id = v_existing;
    end if;
  end if;
  if tg_op = 'UPDATE' then
    if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
      update public.reservations set status = 'cancelled', updated_at = now()
        where beo_id = new.id;
    end if;
    if new.status is distinct from old.status then
      insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)
        values (new.venue_id, new.lead_id, auth.uid(), 'beo_status_changed',
          old.status || ' -> ' || new.status);
    end if;
  end if;
  return new;
end;
$$;
create trigger trg_crm_beos_sync_reservation_insert
  after insert on public.crm_beos
  for each row execute function app_hidden.crm_beos_sync_reservation();

-- Concurrent co-owners deleting themselves must serialize before the original
-- sole-owner check. Once the first deletion commits, the second sees that it
-- would leave the organization ownerless and is rejected.
alter function public.request_account_deletion(text)
  rename to request_account_deletion_impl;
revoke all on function public.request_account_deletion_impl(text)
  from public, anon, authenticated;
create function public.request_account_deletion(p_reason text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Must be signed in to delete your account' using errcode = '42501';
  end if;
  for v_org_id in
    select distinct organization_id from public.memberships
    where user_id = auth.uid() and role = 'organization_owner'
    order by organization_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('owner-deletion:' || v_org_id::text, 0));
  end loop;
  return public.request_account_deletion_impl(p_reason);
end;
$$;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- Keep one live invitation per email while retaining any number of historical
-- accepted/revoked invitations for re-invites.
alter table public.invites drop constraint invites_venue_id_email_status_key;
create unique index invites_one_pending_email_per_venue
  on public.invites (venue_id, email) where status = 'pending';

create or replace function public.unregister_push_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  update public.push_tokens
    set enabled = false, disabled_at = now(), updated_at = now()
    where user_id = auth.uid() and token = p_token;
end;
$$;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;

create or replace function public.register_push_token(
  p_venue_id uuid, p_token text, p_platform text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_org_id uuid;
  v_user_id uuid := auth.uid();
  v_id uuid;
begin
  if v_user_id is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'User is not a member of this venue' using errcode = '42501';
  end if;
  select organization_id into v_org_id from public.venues where id = p_venue_id;
  perform pg_advisory_xact_lock(hashtext('push-token:' || p_venue_id::text || ':' || p_token));
  -- The caller has the live device token. Transfer ownership even if the last
  -- user signed out offline and could not disable their registration remotely.
  insert into public.push_tokens (
    organization_id, venue_id, user_id, token, platform, enabled, last_seen_at,
    disabled_at, updated_at
  ) values (
    v_org_id, p_venue_id, v_user_id, p_token, p_platform, true, now(), null, now()
  ) on conflict (venue_id, token) do update
    set user_id = excluded.user_id, enabled = true, disabled_at = null,
        platform = excluded.platform, last_seen_at = now(), updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- Broadcast read state belongs to each recipient, never to the shared event.
create table public.notification_reads (
  event_id uuid not null references public.notification_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index notification_reads_user_idx on public.notification_reads(user_id);
alter table public.notification_reads enable row level security;
alter table public.notification_reads force row level security;
create policy notification_reads_select_own on public.notification_reads
  for select to authenticated using (user_id = auth.uid());
grant select on public.notification_reads to authenticated;

drop policy notification_events_update on public.notification_events;
drop policy notification_events_select on public.notification_events;
create policy notification_events_select on public.notification_events
  for select to authenticated using (
    target_user_id = auth.uid()
    or (target_user_id is null and app_hidden.is_venue_member(venue_id)
      and (audience = 'venue_staff'
        or (audience = 'venue_managers' and app_hidden.has_venue_role(
          venue_id,
          array['venue_manager','organization_owner','organization_admin']::public.app_role[]))
        or (audience = 'organization_owners' and app_hidden.has_org_role(
          organization_id, array['organization_owner']::public.app_role[]))))
  );
create policy notification_events_update_own on public.notification_events
  for update to authenticated
  using (target_user_id = auth.uid())
  with check (target_user_id = auth.uid());

create or replace function public.notification_feed_for_me(
  p_venue_id uuid, p_limit integer default 50
) returns table (
  id uuid, organization_id uuid, venue_id uuid, target_user_id uuid,
  audience text, kind text, title text, body text, data jsonb,
  read_at timestamptz, created_at timestamptz
) language sql stable security invoker set search_path = '' as $$
  select e.id, e.organization_id, e.venue_id, e.target_user_id,
         e.audience, e.kind, e.title, e.body, e.data,
         case when e.target_user_id is null then r.read_at else e.read_at end,
         e.created_at
  from public.notification_events e
  left join public.notification_reads r
    on r.event_id = e.id and r.user_id = auth.uid()
  where e.venue_id = p_venue_id
  order by e.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;
revoke all on function public.notification_feed_for_me(uuid,integer) from public, anon;
grant execute on function public.notification_feed_for_me(uuid,integer) to authenticated;

create or replace function app_hidden.can_receive_notification(p_event_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.notification_events e
    where e.id = p_event_id and (
      e.target_user_id = auth.uid()
      or (e.target_user_id is null and app_hidden.is_venue_member(e.venue_id)
        and (e.audience = 'venue_staff'
          or (e.audience = 'venue_managers' and app_hidden.has_venue_role(
            e.venue_id,
            array['venue_manager','organization_owner','organization_admin']::public.app_role[]))
          or (e.audience = 'organization_owners' and app_hidden.has_org_role(
            e.organization_id, array['organization_owner']::public.app_role[])))))
  );
$$;

create or replace function public.mark_notification_read_for_me(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_target uuid;
begin
  if auth.uid() is null or not app_hidden.can_receive_notification(p_event_id) then
    raise exception 'notification is not available to this user' using errcode = '42501';
  end if;
  select target_user_id into v_target from public.notification_events where id = p_event_id;
  if v_target is null then
    insert into public.notification_reads(event_id,user_id) values(p_event_id,auth.uid())
      on conflict (event_id,user_id) do nothing;
  else
    update public.notification_events set read_at = coalesce(read_at,now())
      where id = p_event_id and target_user_id = auth.uid();
  end if;
end;
$$;
revoke all on function public.mark_notification_read_for_me(uuid) from public, anon;
grant execute on function public.mark_notification_read_for_me(uuid) to authenticated;

create or replace function public.mark_all_notifications_read_for_me(p_venue_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'venue is not available to this user' using errcode = '42501';
  end if;
  for v_id in
    select id from public.notification_events
    where venue_id = p_venue_id and app_hidden.can_receive_notification(id)
  loop
    perform public.mark_notification_read_for_me(v_id);
  end loop;
end;
$$;
revoke all on function public.mark_all_notifications_read_for_me(uuid) from public, anon;
grant execute on function public.mark_all_notifications_read_for_me(uuid) to authenticated;

-- Advance attempts before the exception subtransaction. A failing storage
-- DELETE rolls back its own effects but cannot roll back the claim counter.
create or replace function app_hidden.prepare_storage_deletion_job_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not app_hidden.is_safe_storage_deletion_path(new.bucket_id, new.object_path) then
    raise exception 'Refusing to queue storage path not matching allowed format'
      using errcode = '42501';
  end if;
  if new.organization_id is null and new.venue_id is not null then
    select organization_id into new.organization_id
      from public.venues where id = new.venue_id;
  end if;
  if new.organization_id is null then
    raise exception 'storage_deletion_jobs requires an organization_id'
      using errcode = '23502';
  end if;
  if new.attempts >= 10 and new.status in ('pending', 'failed') then
    new.status := 'dead';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_hidden.process_storage_deletion_batch(
  p_batch_size integer default 10
) returns table (
  processed_count integer,
  completed_count integer,
  failed_count integer,
  dead_count integer
)
language plpgsql security definer set search_path = public, storage as $$
declare
  r record;
  v_processed integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_dead integer := 0;
  v_error text;
begin
  perform set_config('storage.allow_delete_query', 'true', true);
  for r in
    select id, bucket_id, object_path, attempts
    from public.storage_deletion_jobs
    where status in ('pending', 'failed') and attempts < 10
    order by created_at asc
    limit p_batch_size for update skip locked
  loop
    v_processed := v_processed + 1;
    update public.storage_deletion_jobs
      set status = 'processing', attempts = attempts + 1, updated_at = now()
      where id = r.id;
    if not app_hidden.is_safe_storage_deletion_path(r.bucket_id, r.object_path) then
      update public.storage_deletion_jobs
        set status = 'dead',
            last_error = 'Refusing to delete key not matching the expected storage-path format',
            updated_at = now()
        where id = r.id;
      v_dead := v_dead + 1;
      continue;
    end if;
    begin
      delete from storage.objects
        where bucket_id = r.bucket_id and name = r.object_path;
      update public.storage_deletion_jobs
        set status = 'completed', completed_at = now(), last_error = null,
            updated_at = now()
        where id = r.id;
      v_completed := v_completed + 1;
    exception when others then
      v_error := substring(sqlerrm from 1 for 1000);
      if r.attempts + 1 >= 10 then
        update public.storage_deletion_jobs
          set status = 'dead', last_error = v_error, updated_at = now()
          where id = r.id;
        v_dead := v_dead + 1;
      else
        update public.storage_deletion_jobs
          set status = 'failed', last_error = v_error, updated_at = now()
          where id = r.id;
        v_failed := v_failed + 1;
      end if;
    end;
  end loop;
  return query select v_processed, v_completed, v_failed, v_dead;
end;
$$;

-- Publish only future scheduled shifts, while still sending cancellations for mapped shifts.
create or replace function public.publish_pos_schedule(p_connection_id uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  c public.pos_connections%rowtype;
  v bigint;
  s public.shifts%rowtype;
  m public.pos_external_shift_mappings%rowtype;
  op text;
  employee_external text;
  job_external text;
  location_external text;
  required_capability text;
begin
  select * into c from public.pos_connections where id = p_connection_id for update;
  if not found or not app_hidden.has_venue_role(c.venue_id,
      array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'forbidden_pos_connection' using errcode = '42501';
  end if;
  if c.readiness <> 'connected' or c.status <> 'active' then
    raise exception 'pos_connection_not_ready' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.pos_outbound_jobs
    where connection_id = c.id and status <> 'synced') then
    raise exception 'previous_pos_publication_unresolved' using errcode = 'P0001';
  end if;
  select external_location_id into location_external from public.pos_location_mappings
    where connection_id = c.id and venue_id = c.venue_id;
  if location_external is null then
    raise exception 'missing_location_mapping' using errcode = 'P0001';
  end if;
  insert into public.pos_schedule_versions(connection_id) values (c.id)
    on conflict (connection_id) do nothing;
  update public.pos_schedule_versions set version = version + 1,
    published_at = now(), published_by = auth.uid()
    where connection_id = c.id returning version into v;
  for s in select sh.* from public.shifts sh where sh.venue_id = c.venue_id
    and ((sh.status = 'scheduled' and sh.end_time > now()) or (sh.status = 'cancelled' and exists (select 1 from public.pos_external_shift_mappings x
      where x.connection_id = c.id and x.shift_id = sh.id and x.sync_status <> 'cancelled')))
    order by sh.id loop
    select * into m from public.pos_external_shift_mappings
      where connection_id = c.id and shift_id = s.id;
    if m.ownership = 'external' then
      raise exception 'external_shift_conflict' using errcode = 'P0001';
    end if;
    if s.status = 'cancelled' then
      if m.external_shift_id is null then continue; end if;
      op := 'cancel';
    elsif m.external_shift_id is null then op := 'create';
    else op := 'update'; end if;
    required_capability := 'scheduled_shifts_' || op;
    if not exists (select 1 from public.pos_connection_capabilities
      where connection_id = c.id and capability = required_capability
        and state = 'verified_supported') then
      raise exception 'unsupported_or_unverified_capability: %', required_capability
        using errcode = 'P0001';
    end if;
    if c.provider = 'square' and not exists (select 1 from public.pos_connection_capabilities
      where connection_id = c.id and capability = 'scheduled_shifts_publish'
        and state = 'verified_supported') then
      raise exception 'unsupported_or_unverified_capability: scheduled_shifts_publish'
        using errcode = 'P0001';
    end if;
    if op <> 'cancel' then
      if s.staff_id is null or s.role_label is null then
        raise exception 'unassigned_or_unroled_shift: %', s.id using errcode = 'P0001';
      end if;
      select external_employee_id into employee_external from public.pos_employee_mappings
        where connection_id = c.id and staff_id = s.staff_id;
      select external_job_id into job_external from public.pos_job_mappings
        where connection_id = c.id and role_label = s.role_label;
      if employee_external is null or job_external is null then
        raise exception 'missing_employee_or_job_mapping: %', s.id using errcode = 'P0001';
      end if;
    end if;
    insert into public.pos_external_shift_mappings(connection_id, shift_id)
      values (c.id, s.id) on conflict (connection_id, shift_id) do nothing;
    insert into public.pos_outbound_jobs(connection_id, shift_id, version,
      operation, snapshot, idempotency_key) values (c.id, s.id, v, op,
      jsonb_build_object('venue_id', c.venue_id, 'external_location_id', location_external,
        'external_employee_id', employee_external, 'external_job_id', job_external,
        'external_shift_id', m.external_shift_id, 'provider_revision', m.provider_revision,
        'start_time', s.start_time, 'end_time', s.end_time,
        'timezone', (select timezone from public.venues where id = c.venue_id)),
      c.id::text || ':' || s.id::text || ':' || v::text);
    employee_external := null; job_external := null;
  end loop;
  insert into public.pos_audit_events(connection_id, actor_id, event_type, detail)
    values (c.id, auth.uid(), 'schedule_published', jsonb_build_object('version', v));
  return v;
end $$;


-- Reject traversal path segments but allow legitimate doubled dots in filenames.
create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_bucket_id not in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat', 'profile-photos') then
    return false;
  end if;

  if p_object_path ~ '(^|/)[.][.](/|$)' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  if p_bucket_id = 'chat' then
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    -- Legacy 3-segment chat objects (pre-scoping) still deletable.
    if p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$' then
      return true;
    end if;
    return false;
  end if;

  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;
