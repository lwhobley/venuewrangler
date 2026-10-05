-- Phase 3: AI usage tracking and pre-spend budget reservations, backing the ai-assistant
-- Edge Function's "configurable monthly budget limits" and "audit and usage records"
-- requirements. Both tables are written exclusively by the service role (the Edge Function) —
-- there is no insert/update/delete policy for `authenticated` on either, matching the
-- foundation migration's audit_log pattern: a client can read its own organization's spend,
-- never forge it.

create table public.ai_usage_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid references public.venues (id) on delete set null,
  user_id uuid references auth.users (id),
  task text not null,
  model text not null,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cost_usd numeric(10, 4) not null default 0,
  created_at timestamptz not null default now()
);

create index ai_usage_events_organization_id_idx on public.ai_usage_events (organization_id);
create index ai_usage_events_created_at_idx on public.ai_usage_events (created_at);

-- A reservation is placed before calling the model (an upper-bound cost estimate) and
-- resolved afterward (committed with the actual cost, or released on failure) — this is what
-- blocks two concurrent requests from each separately checking "are we under budget?",
-- getting "yes", and jointly spending more than the limit. The Edge Function is responsible
-- for the reserve -> call -> commit/release lifecycle; the database just stores the state.
create table public.ai_budget_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  reserved_usd numeric(10, 4) not null check (reserved_usd >= 0),
  status text not null default 'pending' check (status in ('pending', 'committed', 'released')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index ai_budget_reservations_organization_id_idx on public.ai_budget_reservations (organization_id);
create index ai_budget_reservations_status_idx on public.ai_budget_reservations (status);

-- Sum of committed spend plus still-pending (not yet expired) reservations for the current
-- calendar month — what the Edge Function checks before approving a new request. A plain SQL
-- function (not security definer) is enough here: it's only ever called by the service role,
-- which bypasses RLS anyway.
create or replace function public.ai_org_spend_this_month(p_org_id uuid)
returns numeric
language sql
stable
set search_path = public
as $$
  select
    coalesce((
      select sum(cost_usd) from public.ai_usage_events
      where organization_id = p_org_id
        and created_at >= date_trunc('month', now())
    ), 0)
    + coalesce((
      select sum(reserved_usd) from public.ai_budget_reservations
      where organization_id = p_org_id
        and status = 'pending'
        and expires_at > now()
    ), 0);
$$;

alter table public.ai_usage_events enable row level security;
alter table public.ai_usage_events force row level security;
alter table public.ai_budget_reservations enable row level security;
alter table public.ai_budget_reservations force row level security;

create policy ai_usage_events_select_org_admins on public.ai_usage_events
  for select to authenticated
  using (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));

create policy ai_budget_reservations_select_org_admins on public.ai_budget_reservations
  for select to authenticated
  using (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));
