do $$ begin
  if (select count(*) from public.inventory_items where venue_id='93000000-0000-0000-0000-000000000001')<>5 then raise exception 'Migration lost legacy items'; end if;
  if not exists(select 1 from public.inventory_items where id='94000000-0000-0000-0000-000000000001' and name='Legacy Vodka' and quantity=6.5 and unit='bottle' and unit_cost_usd=24.5 and count_unit='Bottle') then raise exception 'Migration changed vodka fields'; end if;
  if not exists(select 1 from public.inventory_stock where inventory_item_id='94000000-0000-0000-0000-000000000002' and quantity=14.25) then raise exception 'Migration lost decimal food stock'; end if;
  if not exists(select 1 from public.inventory_items where id='94000000-0000-0000-0000-000000000003' and count_unit='Custom' and custom_count_unit='sleeve of 20') then raise exception 'Migration lost custom unit'; end if;
  if not exists(select 1 from public.inventory_stock where inventory_item_id='94000000-0000-0000-0000-000000000004' and quantity=-2.5) then raise exception 'Migration changed negative legacy quantity'; end if;
  if not exists(select 1 from public.inventory_stock where inventory_item_id='94000000-0000-0000-0000-000000000005' and quantity is null) then raise exception 'Migration invented an unknown opening quantity'; end if;
  if exists(select 1 from public.inventory_stock s join public.inventory_areas a on a.id=s.area_id join public.inventory_items i on i.id=s.inventory_item_id join public.inventory_categories c on c.id=i.category_id where s.venue_id='93000000-0000-0000-0000-000000000001' and (a.name<>'General Inventory' or c.name<>'Uncategorized' or s.organization_id<>'92000000-0000-0000-0000-000000000001')) then raise exception 'Migration lost scope or invented classification'; end if;
  if (select count(*) from public.inventory_history where venue_id='93000000-0000-0000-0000-000000000001' and reference_type='migration')<>5 then raise exception 'Migration lacks opening audit history'; end if;
end $$;
