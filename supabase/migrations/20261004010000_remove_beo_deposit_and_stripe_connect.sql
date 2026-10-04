-- Removes the BEO deposit-collection feature entirely. Stripe is now used
-- only for the platform app-subscription (see stripe-webhook), never for
-- Stripe Connect / connected-account charges. There is no other mechanism to
-- ever mark a BEO deposit "paid", so the whole due/paid/waived concept is
-- removed rather than left half-functional.

-- 1. Drop the now-dead waive RPC before the columns it reads disappear.
revoke execute on function public.waive_beo_deposit(uuid) from authenticated;
drop function public.waive_beo_deposit(uuid);

-- 2. convert_beo_to_contract: drop the unpaid-deposit gate and the deposit
-- line item in the generated payment schedule.
create or replace function public.convert_beo_to_contract(p_beo_id uuid)
returns table (contract_id uuid, already_existed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_beo record;
  v_existing_id uuid;
  v_new_id uuid;
begin
  select * into v_beo from public.crm_beos where id = p_beo_id;
  if v_beo.id is null then
    raise exception 'beo % does not exist', p_beo_id using errcode = '23503';
  end if;

  if not app_hidden.has_venue_role(
    v_beo.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  select id into v_existing_id
  from public.crm_contracts
  where beo_id = p_beo_id and status <> 'cancelled'
  limit 1;

  if v_existing_id is not null then
    return query select v_existing_id, true;
    return;
  end if;

  insert into public.crm_contracts (
    venue_id, lead_id, beo_id, contract_number, event_name, event_date, guest_count, venue_space,
    fb_minimum_cents, payment_schedule, status
  ) values (
    v_beo.venue_id, v_beo.lead_id, p_beo_id, null, v_beo.event_name, v_beo.event_date, v_beo.guest_count,
    v_beo.venue_space, v_beo.fb_minimum_cents, '[]'::jsonb, 'draft'
  )
  returning id into v_new_id;

  return query select v_new_id, false;
end;
$$;

-- 3. render_email_template: drop the event.deposit template variable.
create or replace function public.render_email_template(
  p_template_id uuid,
  p_lead_id uuid default null,
  p_beo_id uuid default null
)
returns table (subject text, body text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template record;
  v_venue record;
  v_lead record;
  v_beo record;
  v_vars jsonb := '{}'::jsonb;
  v_subject text;
  v_body text;
  v_key text;
begin
  select * into v_template from public.email_templates where id = p_template_id;
  if v_template.id is null then
    raise exception 'template % does not exist', p_template_id using errcode = '23503';
  end if;

  if not app_hidden.has_venue_role(
    v_template.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  select name into v_venue from public.venues where id = v_template.venue_id;
  v_vars := jsonb_build_object('venue.name', coalesce(v_venue.name, ''));

  if p_lead_id is not null then
    select * into v_lead from public.crm_leads where id = p_lead_id and venue_id = v_template.venue_id;
    if v_lead.id is not null then
      v_vars := v_vars || jsonb_build_object(
        'lead.name', coalesce(v_lead.full_name, ''),
        'lead.firstName', coalesce(split_part(v_lead.full_name, ' ', 1), ''),
        'lead.email', coalesce(v_lead.email, ''),
        'lead.phone', coalesce(v_lead.phone, ''),
        'lead.company', coalesce(v_lead.company, ''),
        'lead.source', coalesce(v_lead.source, '')
      );
    end if;
  end if;

  if p_beo_id is not null then
    select * into v_beo from public.crm_beos where id = p_beo_id and venue_id = v_template.venue_id;
    if v_beo.id is not null then
      v_vars := v_vars || jsonb_build_object(
        'event.name', coalesce(v_beo.event_name, ''),
        'event.date', coalesce(to_char(v_beo.event_date, 'FMMonth FMDD, YYYY'), ''),
        'event.space', coalesce(v_beo.venue_space, ''),
        'event.guestCount', coalesce(v_beo.guest_count::text, '')
      );
    end if;
  end if;

  v_subject := v_template.subject;
  v_body := v_template.body;
  for v_key in select jsonb_object_keys(v_vars) loop
    v_subject := replace(v_subject, '{{' || v_key || '}}', v_vars ->> v_key);
    v_body := replace(v_body, '{{' || v_key || '}}', v_vars ->> v_key);
  end loop;

  return query select v_subject, v_body;
end;
$$;

-- 4. crm_beos_derive trigger: drop the paid-deposit-immutability check (the
-- columns it guards are about to be dropped).
create or replace function app_hidden.crm_beos_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_lead_venue_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;

    if new.lead_id is not null then
      select venue_id into v_lead_venue_id from public.crm_leads where id = new.lead_id;
      if v_lead_venue_id is null or v_lead_venue_id <> new.venue_id then
        raise exception 'lead % does not belong to venue %', new.lead_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;

    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

-- 5. Drop the deposit columns themselves.
alter table public.crm_beos
  drop column deposit_cents,
  drop column deposit_due_date,
  drop column deposit_status,
  drop column deposit_checkout_session_id,
  drop column deposit_payment_intent_id,
  drop column deposit_paid_at,
  drop column deposit_checkout_account_id,
  drop column deposit_checkout_nonce;

-- 6. Restore plain (non-column-restricted) insert/update grants on
-- crm_beos — the column-level restriction existed only to protect the
-- deposit/payment columns dropped above.
revoke insert on public.crm_beos from authenticated;
grant insert on public.crm_beos to authenticated;
revoke update on public.crm_beos from authenticated;
grant update on public.crm_beos to authenticated;

-- 7. Drop the Stripe Connect merchant-account table. Stripe is subscription
-- billing only now; no connected accounts exist for venues.
drop table public.organization_stripe_accounts;
