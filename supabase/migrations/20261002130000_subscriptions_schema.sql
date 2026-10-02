-- Phase 3 feature: Stripe billing. One row per organization (not per venue — billing is an
-- org-level concern, same scope as memberships' org-level roles). Written exclusively by the
-- `stripe-webhook` Edge Function using the service role: a client can read its own
-- organization's subscription state to gate UI, but can never write it — exactly the same
-- "client reads, service role writes" shape as ai_usage_events.
create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations (id) on delete cascade,
  stripe_customer_id text unique,
  stripe_subscription_id text unique,
  stripe_price_id text,
  status text not null default 'none' check (
    status in (
      'none', 'incomplete', 'incomplete_expired', 'trialing', 'active',
      'past_due', 'canceled', 'unpaid', 'paused'
    )
  ),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index subscriptions_stripe_customer_id_idx on public.subscriptions (stripe_customer_id);

-- "active" and "trialing" are the only states that should unlock paid functionality — a
-- helper so every call site (RLS or Flutter) applies the exact same definition rather than
-- re-deriving it.
create or replace function public.subscription_is_entitled(p_status text)
returns boolean
language sql
immutable
as $$
  select p_status in ('active', 'trialing');
$$;

alter table public.subscriptions enable row level security;
alter table public.subscriptions force row level security;

create policy subscriptions_select_org_admins on public.subscriptions
  for select to authenticated
  using (app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[]));
