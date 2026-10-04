-- Fix MEDIUM: Stripe webhook order-safety + idempotency.
-- Out-of-order `customer.subscription.updated` delivery could overwrite newer status,
-- and reparking the same event id twice double-applied. Track processed events and the
-- last applied event timestamp per subscription row.

alter table public.subscriptions
  add column if not exists last_event_id text,
  add column if not exists last_event_created bigint;

create table if not exists public.stripe_processed_events (
  event_id text primary key,
  event_type text not null,
  created_at timestamptz not null default now()
);

alter table public.stripe_processed_events enable row level security;
alter table public.stripe_processed_events force row level security;
-- Service-role only: written by stripe-webhook, never read by clients.
revoke all on public.stripe_processed_events from authenticated, anon;
