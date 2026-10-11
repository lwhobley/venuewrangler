-- Serialize BEO conversion and protect the one-live-contract-per-BEO invariant even when
-- callers bypass the conversion RPC. Existing duplicate live contracts must be reconciled
-- before this unique index can be applied to a database containing such rows.
create unique index crm_contracts_one_live_per_beo_idx
  on public.crm_contracts (beo_id)
  where beo_id is not null and status <> 'cancelled';

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
  select * into v_beo
  from public.crm_beos
  where id = p_beo_id
  for update;
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
  order by created_at
  limit 1;
  if v_existing_id is not null then
    return query select v_existing_id, true;
    return;
  end if;

  insert into public.crm_contracts (
    venue_id, lead_id, beo_id, contract_number, event_name, event_date, guest_count,
    venue_space, fb_minimum_cents, payment_schedule, status
  ) values (
    v_beo.venue_id, v_beo.lead_id, p_beo_id, null, v_beo.event_name, v_beo.event_date,
    v_beo.guest_count, v_beo.venue_space, v_beo.fb_minimum_cents, '[]'::jsonb, 'draft'
  ) returning id into v_new_id;

  return query select v_new_id, false;
end;
$$;

revoke execute on function public.convert_beo_to_contract(uuid) from public, anon;
grant execute on function public.convert_beo_to_contract(uuid) to authenticated;
