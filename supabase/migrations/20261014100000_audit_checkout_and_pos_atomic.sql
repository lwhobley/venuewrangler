-- Compare-and-swap expired checkout attempts. Reuse a replacement claimed by
-- another request, rather than rotating its idempotency key a second time.
drop function public.claim_subscription_checkout_attempt(uuid, boolean);
create function public.claim_subscription_checkout_attempt(
  p_organization_id uuid, p_force_new boolean default false,
  p_expected_key uuid default null
) returns table (idempotency_key uuid, stripe_session_id text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_attempt public.subscription_checkout_attempts%rowtype;
begin
  if not exists (select 1 from public.organizations where id = p_organization_id) then
    raise exception 'organization does not exist' using errcode = '23503';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('stripe-checkout:' || p_organization_id::text, 0));
  insert into public.subscription_checkout_attempts (organization_id)
    values (p_organization_id) on conflict (organization_id) do nothing;
  select * into v_attempt from public.subscription_checkout_attempts
    where organization_id = p_organization_id for update;
  if (p_force_new and v_attempt.idempotency_key = p_expected_key)
     or (v_attempt.stripe_session_id is null and v_attempt.expires_at <= now()) then
    update public.subscription_checkout_attempts
      set idempotency_key = gen_random_uuid(), stripe_session_id = null,
          expires_at = now() + interval '30 minutes', updated_at = now()
      where organization_id = p_organization_id returning * into v_attempt;
  end if;
  return query select v_attempt.idempotency_key, v_attempt.stripe_session_id, v_attempt.expires_at;
end;
$$;
revoke all on function public.claim_subscription_checkout_attempt(uuid, boolean, uuid) from public, anon, authenticated;
grant execute on function public.claim_subscription_checkout_attempt(uuid, boolean, uuid) to service_role;

-- UPDATE locks serialize conflicting webhook upserts. Evaluate the *locked*
-- current row, so a stale open event cannot undo a close or void.
create function app_hidden.guard_pos_check_final_state() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.venue_id is distinct from old.venue_id then
    raise exception 'venue_id cannot be modified once set' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id then
    raise exception 'organization_id cannot be modified once set' using errcode = '42501';
  end if;
  if old.status = 'voided' or (old.status = 'closed' and new.status <> 'voided') then
    return old;
  end if;
  return new;
end;
$$;
create trigger guard_pos_check_final_state before update on public.pos_checks
  for each row execute function app_hidden.guard_pos_check_final_state();
