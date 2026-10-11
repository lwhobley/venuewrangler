-- Store one reusable Stripe Checkout attempt per organization. The per-organization advisory
-- lock and Stripe idempotency key ensure concurrent Edge Function requests create one session.
create table public.subscription_checkout_attempts (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  idempotency_key uuid not null default gen_random_uuid(),
  stripe_session_id text,
  expires_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.subscription_checkout_attempts enable row level security;
alter table public.subscription_checkout_attempts force row level security;
revoke all on public.subscription_checkout_attempts from public, anon, authenticated;

create or replace function public.claim_subscription_checkout_attempt(
  p_organization_id uuid,
  p_force_new boolean default false
) returns table (idempotency_key uuid, stripe_session_id text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt public.subscription_checkout_attempts%rowtype;
begin
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception 'organization does not exist' using errcode = '23503';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('stripe-checkout:' || p_organization_id::text, 0)
  );
  insert into public.subscription_checkout_attempts (organization_id)
  values (p_organization_id) on conflict (organization_id) do nothing;

  select * into v_attempt
  from public.subscription_checkout_attempts
  where organization_id = p_organization_id
  for update;

  if p_force_new or v_attempt.expires_at <= now() then
    update public.subscription_checkout_attempts
    set idempotency_key = gen_random_uuid(), stripe_session_id = null,
        expires_at = now() + interval '30 minutes', updated_at = now()
    where organization_id = p_organization_id
    returning * into v_attempt;
  end if;
  return query select v_attempt.idempotency_key, v_attempt.stripe_session_id, v_attempt.expires_at;
end;
$$;

create or replace function public.record_subscription_checkout_session(
  p_organization_id uuid,
  p_idempotency_key uuid,
  p_stripe_session_id text,
  p_expires_at timestamptz
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated integer;
begin
  update public.subscription_checkout_attempts
  set stripe_session_id = p_stripe_session_id,
      expires_at = p_expires_at,
      updated_at = now()
  where organization_id = p_organization_id
    and idempotency_key = p_idempotency_key;
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;

revoke all on function public.claim_subscription_checkout_attempt(uuid, boolean) from public, anon, authenticated;
revoke all on function public.record_subscription_checkout_session(uuid, uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_subscription_checkout_attempt(uuid, boolean) to service_role;
grant execute on function public.record_subscription_checkout_session(uuid, uuid, text, timestamptz) to service_role;
