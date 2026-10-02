-- Phase 4 feature: Groq-powered AI shift insights.
-- Replaces legacy CosmicInsight with venue- and shift-scoped actionable AI operational insights.
-- RLS: all venue members can view shift insights; managers (and service role) can insert/update/delete.
-- Triggers derive organization_id from venue_id (derive, don't trust) and validate shift_id linkage.

create table public.shift_insights (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  shift_id uuid references public.shifts (id) on delete cascade,
  kind text not null default 'shift_summary' check (
    kind in (
      'shift_summary',
      'coverage_warning',
      'labor_efficiency',
      'rush_prep',
      'fatigue_risk',
      'station_balance',
      'compliance_note'
    )
  ),
  title text not null check (char_length(trim(title)) > 0),
  body text not null check (char_length(trim(body)) > 0),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index shift_insights_venue_id_idx on public.shift_insights (venue_id);
create index shift_insights_organization_id_idx on public.shift_insights (organization_id);
create index shift_insights_shift_id_idx on public.shift_insights (shift_id);
create index shift_insights_created_at_idx on public.shift_insights (created_at desc);

create or replace function app_hidden.prepare_shift_insight_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create trigger prepare_shift_insight_insert
  before insert on public.shift_insights
  for each row execute function app_hidden.prepare_shift_insight_insert();

create or replace function app_hidden.sync_shift_insight_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create trigger sync_shift_insight_update
  before update on public.shift_insights
  for each row execute function app_hidden.sync_shift_insight_update();

alter table public.shift_insights enable row level security;
alter table public.shift_insights force row level security;

create policy shift_insights_select_venue_members on public.shift_insights
  for select to authenticated
  using (app_hidden.is_venue_member(venue_id));

create policy shift_insights_insert_managers on public.shift_insights
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy shift_insights_update_managers on public.shift_insights
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy shift_insights_delete_managers on public.shift_insights
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );
