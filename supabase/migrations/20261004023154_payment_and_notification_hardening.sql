-- Payment state is written by Stripe's webhook (service role) or by the
-- explicitly authorized waive_beo_deposit SECURITY DEFINER RPC. A manager may
-- edit BEO content, but cannot mark a deposit paid or replace its Checkout ID.
alter table public.crm_beos
  add column deposit_checkout_account_id text
  check (deposit_checkout_account_id is null or deposit_checkout_account_id ~ '^acct_[A-Za-z0-9]+$');
alter table public.crm_beos
  add column deposit_checkout_nonce uuid not null default gen_random_uuid();

alter table public.crm_beos alter column deposit_status set default 'due';
revoke insert on public.crm_beos from authenticated;
grant insert (
  id, venue_id, lead_id, event_name, event_date, event_type, guest_count,
  venue_space, setup_style, fb_minimum_cents, deposit_cents,
  deposit_due_date, menu_appetizers, menu_entrees, menu_desserts,
  menu_bar_package, special_requirements, internal_notes, assigned_rep_id,
  status
) on public.crm_beos to authenticated;

revoke update on public.crm_beos from authenticated;
grant update (
  lead_id, event_name, event_date, event_type, guest_count, venue_space,
  setup_style, fb_minimum_cents, deposit_due_date, menu_appetizers,
  menu_entrees, menu_desserts, menu_bar_package, special_requirements,
  internal_notes, assigned_rep_id, status
) on public.crm_beos to authenticated;

-- Clients can only change read state. Keep the existing RLS update policy so
-- venue managers can still acknowledge audience-wide venue notifications.
revoke update on public.notification_events from authenticated;
grant update (read_at) on public.notification_events to authenticated;

-- The connected account accepting event deposits belongs to the organization,
-- never to the platform's app-subscription customer record.
create table public.organization_stripe_accounts (
  organization_id uuid primary key references public.organizations (id) on delete cascade,
  stripe_account_id text not null unique check (stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.organization_stripe_accounts enable row level security;
alter table public.organization_stripe_accounts force row level security;
create policy organization_stripe_accounts_select on public.organization_stripe_accounts
  for select to authenticated
  using (app_hidden.has_org_role(
    organization_id,
    array['organization_owner', 'organization_admin']::public.app_role[]
  ));
revoke all on public.organization_stripe_accounts from public, anon, authenticated;
grant select on public.organization_stripe_accounts to authenticated;
