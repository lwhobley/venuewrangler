-- Phase 4 feature: push_tokens and notification_events.
-- Direct FCM + APNs integration, in-app notification feed, advisory-locked token registration,
-- and dead token auto-disabling.

create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null check (char_length(trim(token)) > 0 and char_length(token) <= 500),
  platform text not null check (platform in ('ios', 'android', 'web')),
  enabled boolean not null default true,
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_tokens_venue_token_key unique (venue_id, token)
);

create index if not exists push_tokens_venue_user_idx
  on public.push_tokens (venue_id, user_id)
  where enabled = true;

create index if not exists push_tokens_token_idx
  on public.push_tokens (token);

create table if not exists public.notification_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  target_user_id uuid references auth.users (id) on delete cascade,
  audience text not null default 'user' check (audience in ('user', 'venue_managers', 'venue_staff', 'organization_owners')),
  kind text not null check (char_length(trim(kind)) > 0),
  title text not null check (char_length(trim(title)) > 0),
  body text not null check (char_length(trim(body)) > 0),
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notification_events_feed_idx
  on public.notification_events (venue_id, target_user_id, created_at desc);

create index if not exists notification_events_audience_idx
  on public.notification_events (venue_id, audience, created_at desc);

-- ---------------------------------------------------------------------------
-- Advisory-locked token registration function
-- Prevents race conditions and stops a token from being claimed by another profile in same venue
-- ---------------------------------------------------------------------------

create or replace function public.register_push_token(
  p_venue_id uuid,
  p_token text,
  p_platform text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_user_id uuid := auth.uid();
  v_existing_user uuid;
  v_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'User is not a member of this venue' using errcode = '42501';
  end if;

  select organization_id into v_org_id from public.venues where id = p_venue_id;

  -- Advisory transaction lock on venue + token pair
  perform pg_advisory_xact_lock(hashtext('push-token:' || p_venue_id::text || ':' || p_token));

  select user_id into v_existing_user
  from public.push_tokens
  where venue_id = p_venue_id and token = p_token;

  if v_existing_user is not null and v_existing_user != v_user_id then
    raise exception 'This device token is already registered to another user at this venue.'
      using errcode = '42501';
  end if;

  insert into public.push_tokens (
    organization_id, venue_id, user_id, token, platform, enabled, last_seen_at, disabled_at, updated_at
  ) values (
    v_org_id, p_venue_id, v_user_id, p_token, p_platform, true, now(), null, now()
  )
  on conflict (venue_id, token) do update
  set enabled = true,
      disabled_at = null,
      platform = excluded.platform,
      last_seen_at = now(),
      updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.register_push_token(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Disable dead tokens (called by push delivery on Unregistered / BadDeviceToken)
-- ---------------------------------------------------------------------------

create or replace function app_hidden.disable_push_tokens(
  p_tokens text[]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ---------------------------------------------------------------------------
-- Helper trigger to derive organization_id for notification_events
-- ---------------------------------------------------------------------------

create or replace function app_hidden.prepare_notification_event_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

drop trigger if exists prepare_notification_event_insert on public.notification_events;
create trigger prepare_notification_event_insert
  before insert on public.notification_events
  for each row execute function app_hidden.prepare_notification_event_insert();

-- ---------------------------------------------------------------------------
-- RLS: push_tokens
-- ---------------------------------------------------------------------------

alter table public.push_tokens enable row level security;
alter table public.push_tokens force row level security;

drop policy if exists push_tokens_select on public.push_tokens;
create policy push_tokens_select on public.push_tokens
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists push_tokens_delete on public.push_tokens;
create policy push_tokens_delete on public.push_tokens
  for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- RLS: notification_events
-- ---------------------------------------------------------------------------

alter table public.notification_events enable row level security;
alter table public.notification_events force row level security;

drop policy if exists notification_events_select on public.notification_events;
create policy notification_events_select on public.notification_events
  for select to authenticated
  using (
    target_user_id = auth.uid()
    or (
      app_hidden.is_venue_member(venue_id)
      and (
        audience = 'venue_staff'
        or (
          audience = 'venue_managers'
          and app_hidden.has_venue_role(
            venue_id,
            array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
          )
        )
        or (
          audience = 'organization_owners'
          and app_hidden.has_org_role(
            organization_id,
            array['organization_owner']::public.app_role[]
          )
        )
      )
    )
  );

drop policy if exists notification_events_update on public.notification_events;
create policy notification_events_update on public.notification_events
  for update to authenticated
  using (
    target_user_id = auth.uid()
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    target_user_id = auth.uid()
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Grants
grant select, delete on public.push_tokens to authenticated;
grant select, update on public.notification_events to authenticated;
