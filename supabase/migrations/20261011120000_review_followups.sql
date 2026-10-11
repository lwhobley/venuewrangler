-- Review follow-ups for the 20261010* migrations.

-- 1. Authorize before locking or revealing whether a BEO exists. Unauthorized callers get the
--    same error whether or not the row exists, and cannot lock another tenant's BEO.
create or replace function public.convert_beo_to_contract(p_beo_id uuid)
returns table (contract_id uuid, already_existed boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_venue_id uuid;
  v_beo public.crm_beos%rowtype;
  v_existing_id uuid;
  v_new_id uuid;
begin
  select b.venue_id into v_venue_id from public.crm_beos b where b.id = p_beo_id;

  if v_venue_id is null or not app_hidden.has_venue_role(
    v_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  select * into v_beo from public.crm_beos b where b.id = p_beo_id for update;
  if not found then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  select c.id into v_existing_id
  from public.crm_contracts c
  where c.beo_id = p_beo_id and c.status <> 'cancelled'
  order by c.created_at
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

-- 2. Storage deletion cron: (re)schedule when the dispatch secrets exist, and warn loudly
--    instead of silently leaving no job when they do not.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from pg_extension where extname = 'pg_net')
       and exists (select 1 from vault.decrypted_secrets where name = 'storage_deletion_dispatch_url')
       and exists (select 1 from vault.decrypted_secrets where name = 'storage_deletion_dispatch_secret') then
      if exists (select 1 from cron.job where jobname = 'storage-deletion-worker') then
        perform cron.unschedule('storage-deletion-worker');
      end if;
      perform cron.schedule(
        'storage-deletion-worker', '*/10 * * * *',
        'select * from app_hidden.process_storage_deletion_batch(25);'
      );
    elsif not exists (select 1 from cron.job where jobname = 'storage-deletion-worker') then
      raise warning 'storage-deletion-worker is NOT scheduled: create Vault secrets storage_deletion_dispatch_url and storage_deletion_dispatch_secret (and enable pg_net), then re-run this block';
    end if;
  end if;
end;
$$;

-- 3. Retention cron: let scheduling errors surface instead of swallowing them.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'retention-cleanup') then
      perform cron.unschedule('retention-cleanup');
    end if;
    perform cron.schedule(
      'retention-cleanup', '17 6 * * *', 'select app_hidden.run_retention_cleanup();'
    );
  end if;
end;
$$;
