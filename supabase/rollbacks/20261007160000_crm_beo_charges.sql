-- Manual reverse migration. Refuses to discard recorded charges.
begin;
do $$
begin
  if exists (select 1 from public.crm_beo_charges limit 1) then
    raise exception 'crm_beo_charges contains data; export and reconcile it before rollback';
  end if;
end;
$$;

drop table public.crm_beo_charges;
alter table public.crm_beos drop constraint crm_beos_id_venue_unique;
commit;
