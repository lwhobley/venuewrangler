-- Restaurant Inventory V2. Additive: legacy items, names, quantities, units and costs survive.
-- All monetary arithmetic uses NUMERIC. Stock/count/history writes go through checked RPCs.
begin;

create table public.inventory_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  inventory_group text not null check (inventory_group in ('Beverage','Food','Non-Food','Uncategorized')),
  is_active boolean not null default true,
  is_default boolean not null default false,
  unique(organization_id,name), unique(id,organization_id)
);
create table public.inventory_subcategories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 100),
  is_active boolean not null default true,
  foreign key(category_id,organization_id) references public.inventory_categories(id,organization_id),
  unique(category_id,name), unique(id,category_id)
);
create table public.inventory_areas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  is_active boolean not null default true,
  is_default boolean not null default false,
  unique(venue_id,name), unique(id,venue_id)
);
create table public.inventory_sub_areas (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  area_id uuid not null,
  name text not null check (length(trim(name)) between 1 and 100),
  is_active boolean not null default true,
  foreign key(area_id,venue_id) references public.inventory_areas(id,venue_id),
  unique(area_id,name), unique(id,area_id)
);

create or replace function app_hidden.seed_inventory_categories(p_org uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; c uuid; sub text;
begin
  for r in select * from (values
    ('Beverage','Liquor',array['Vodka','Tequila','Whiskey/Bourbon','Scotch','Rum','Gin','Cognac/Brandy','Mezcal','Liqueurs/Cordials','Other Spirits']),
    ('Beverage','Wine',array['Red','White','Rosé','Sparkling/Champagne','Dessert/Fortified','Cooking Wine']),
    ('Beverage','Beer',array['Draft','Bottled','Canned','Craft','Non-Alcoholic Beer']),
    ('Beverage','Non-Alcoholic Beverage',array['Water','Soda','Juice','Energy Drinks','Coffee','Tea','Mixers','Syrups','Purées','Other']),
    ('Food','Meat',array['Beef','Pork','Poultry','Lamb','Other']),
    ('Food','Seafood',array['Fish','Shellfish','Other Seafood']),
    ('Food','Produce',array['Fruit','Vegetables','Herbs','Garnishes']),
    ('Food','Dairy & Eggs',array['Milk/Cream','Cheese','Butter','Eggs']),
    ('Food','Dry Goods',array['Rice','Pasta','Flour','Sugar','Grains','Beans','Bread','Cereal']),
    ('Food','Frozen',array['Frozen Protein','Frozen Produce','Frozen Prepared Food','Desserts']),
    ('Food','Sauces & Condiments',array['Sauces','Dressings','Oils','Vinegars','Condiments','Spices/Seasonings']),
    ('Food','Prepared / Prep',array['House Sauces','Prepped Proteins','Prepped Produce','Batch Items','Desserts']),
    ('Non-Food','Disposables',array['Cups','Lids','Straws','Napkins','To-Go Containers','Bags','Utensils','Gloves']),
    ('Non-Food','Cleaning & Chemicals',array['Sanitizer','Detergent','Degreaser','Dish Chemicals','Cleaning Supplies','Trash Bags']),
    ('Non-Food','Operating Supplies',array['Foil','Plastic Wrap','Parchment','Paper Products','Bar Supplies','Kitchen Supplies']),
    ('Non-Food','Smallwares',array['Glassware','Plates','Flatware','Bar Tools','Kitchen Tools','Serving Equipment']),
    ('Uncategorized','Uncategorized',array[]::text[])
  ) as defaults(grp,name,subs) loop
    insert into public.inventory_categories(organization_id,name,inventory_group,is_default)
    values(p_org,r.name,r.grp,r.grp='Uncategorized') on conflict(organization_id,name) do nothing;
    select id into c from public.inventory_categories where organization_id=p_org and name=r.name;
    foreach sub in array r.subs loop
      insert into public.inventory_subcategories(organization_id,category_id,name)
      values(p_org,c,sub) on conflict(category_id,name) do nothing;
    end loop;
  end loop;
end $$;
revoke all on function app_hidden.seed_inventory_categories(uuid) from public,anon,authenticated;
do $$ declare r record; begin
  for r in select id from public.organizations loop perform app_hidden.seed_inventory_categories(r.id); end loop;
end $$;
create function app_hidden.inventory_seed_new_org() returns trigger
language plpgsql security definer set search_path = '' as $$
begin perform app_hidden.seed_inventory_categories(new.id); return new; end $$;
create trigger inventory_seed_new_org after insert on public.organizations
for each row execute function app_hidden.inventory_seed_new_org();
create function app_hidden.inventory_seed_new_venue() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.inventory_areas(organization_id,venue_id,name,is_default) values(new.organization_id,new.id,'General Inventory',true);
  return new;
end $$;
create trigger inventory_seed_new_venue after insert on public.venues
for each row execute function app_hidden.inventory_seed_new_venue();
insert into public.inventory_areas(organization_id,venue_id,name,is_default)
select organization_id,id,'General Inventory',true from public.venues;

alter table public.inventory_items
  alter column quantity type numeric(14,4),
  add column category_id uuid,
  add column subcategory_id uuid,
  add column size_amount numeric(14,4) check (size_amount > 0 and size_amount::text not in ('NaN','Infinity','-Infinity')),
  add column size_unit text check (size_unit in ('mL','L','oz','fl oz','gal','lb','kg','g','count')),
  add column count_unit text not null default 'Each'
    check(count_unit in ('Bottle','Case','Each','Pound','Ounce','Gallon','Liter','Keg','Bag','Box','Pack','Can','Container','Tray','Dozen','Custom')),
  add column custom_count_unit text,
  add column supplier text,
  add column notes text,
  add column is_active boolean not null default true,
  add constraint inventory_items_size_pair check((size_amount is null)=(size_unit is null)),
  add constraint inventory_items_custom_unit check(count_unit <> 'Custom' or coalesce(length(trim(custom_count_unit)),0) > 0),
  add constraint inventory_items_category_org foreign key(category_id,organization_id)
    references public.inventory_categories(id,organization_id),
  add constraint inventory_items_subcategory_parent foreign key(subcategory_id,category_id)
    references public.inventory_subcategories(id,category_id),
  add constraint inventory_items_subcategory_requires_category check(subcategory_id is null or category_id is not null),
  add constraint inventory_items_id_venue unique(id,venue_id);

create function app_hidden.inventory_normalize_unit(p_unit text) returns text
language sql immutable set search_path = '' as $$
select case lower(trim(coalesce(p_unit,'')))
  when '' then 'Each' when 'bottle' then 'Bottle' when 'bottles' then 'Bottle'
  when 'case' then 'Case' when 'cases' then 'Case' when 'each' then 'Each'
  when 'lb' then 'Pound' when 'lbs' then 'Pound' when 'pound' then 'Pound' when 'pounds' then 'Pound'
  when 'oz' then 'Ounce' when 'ounce' then 'Ounce' when 'ounces' then 'Ounce'
  when 'gal' then 'Gallon' when 'gallon' then 'Gallon' when 'gallons' then 'Gallon'
  when 'l' then 'Liter' when 'liter' then 'Liter' when 'liters' then 'Liter'
  when 'keg' then 'Keg' when 'bag' then 'Bag' when 'box' then 'Box' when 'pack' then 'Pack'
  when 'can' then 'Can' when 'container' then 'Container' when 'tray' then 'Tray' when 'dozen' then 'Dozen'
  else 'Custom' end;
$$;
update public.inventory_items i set
  category_id=(select id from public.inventory_categories where organization_id=i.organization_id and is_default),
  count_unit=app_hidden.inventory_normalize_unit(i.unit),
  custom_count_unit=case when app_hidden.inventory_normalize_unit(i.unit)='Custom' then i.unit end;

create table public.inventory_stock (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  inventory_item_id uuid not null,
  area_id uuid not null,
  sub_area_id uuid,
  quantity numeric(14,4), -- null legacy quantity stays unknown until physically counted
  par_level numeric(14,4) check(par_level >= 0 and par_level::text not in ('NaN','Infinity','-Infinity')),
  version bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(inventory_item_id,venue_id) references public.inventory_items(id,venue_id) on delete cascade,
  foreign key(area_id,venue_id) references public.inventory_areas(id,venue_id),
  foreign key(sub_area_id,area_id) references public.inventory_sub_areas(id,area_id),
  unique nulls not distinct(inventory_item_id,area_id,sub_area_id)
);
insert into public.inventory_stock(organization_id,venue_id,inventory_item_id,area_id,quantity)
select i.organization_id,i.venue_id,i.id,a.id,i.quantity
from public.inventory_items i join public.inventory_areas a on a.venue_id=i.venue_id and a.is_default;

create table public.inventory_counts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  area_id uuid references public.inventory_areas(id),
  category_id uuid references public.inventory_categories(id),
  subcategory_id uuid references public.inventory_subcategories(id),
  count_type text not null check(count_type in ('full','partial')),
  status text not null default 'draft' check(status in ('draft','in_progress','completed','cancelled')),
  started_by uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  notes text
);
create table public.inventory_count_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  count_id uuid not null references public.inventory_counts(id) on delete cascade,
  inventory_item_id uuid references public.inventory_items(id) on delete set null,
  stock_id uuid references public.inventory_stock(id) on delete set null,
  item_name text not null,
  location_name text not null,
  count_unit text not null,
  size_label text,
  previous_quantity numeric(14,4),
  stock_version bigint not null,
  counted_quantity numeric(14,4) check(counted_quantity >= 0),
  variance_quantity numeric(14,4) generated always as (counted_quantity-previous_quantity) stored,
  unit_cost_snapshot numeric(10,2),
  variance_value numeric(18,4) generated always as ((counted_quantity-previous_quantity)*unit_cost_snapshot) stored,
  counted_by uuid references auth.users(id) on delete set null,
  counted_at timestamptz,
  unique(count_id,stock_id)
);
create table public.inventory_history (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  inventory_item_id uuid references public.inventory_items(id) on delete set null,
  stock_id uuid references public.inventory_stock(id) on delete set null,
  area_id uuid references public.inventory_areas(id) on delete set null,
  sub_area_id uuid references public.inventory_sub_areas(id) on delete set null,
  item_name text not null,
  location_name text not null,
  count_unit text not null,
  action_type text not null check(action_type in ('COUNT','RECEIVE','TRANSFER_IN','TRANSFER_OUT','WASTE','ADJUSTMENT')),
  previous_quantity numeric(14,4), quantity_change numeric(14,4), new_quantity numeric(14,4),
  unit_cost_snapshot numeric(10,2), reason text, notes text,
  reference_type text, reference_id uuid,
  performed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table app_hidden.inventory_operations (
  id uuid primary key, venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null, payload jsonb not null, result_id uuid not null
);
alter table app_hidden.inventory_operations enable row level security;
revoke all on app_hidden.inventory_operations from public,anon,authenticated;

-- Never trust a client-supplied org; FK pairs and immutable scopes also protect manager edits.
create function app_hidden.inventory_metadata_scope() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name='inventory_subcategories' then
    if tg_op='UPDATE' and new.category_id is distinct from old.category_id then raise exception 'Category parent is immutable' using errcode='22023'; end if;
    select organization_id into new.organization_id from public.inventory_categories where id=new.category_id;
  elsif tg_table_name='inventory_sub_areas' then
    if tg_op='UPDATE' and new.area_id is distinct from old.area_id then raise exception 'Area parent is immutable' using errcode='22023'; end if;
    select venue_id,organization_id into new.venue_id,new.organization_id from public.inventory_areas where id=new.area_id;
  else
    if tg_op='UPDATE' and new.venue_id is distinct from old.venue_id then raise exception 'Venue is immutable' using errcode='22023'; end if;
    select organization_id into new.organization_id from public.venues where id=new.venue_id;
  end if;
  return new;
end $$;
create trigger inventory_metadata_scope before insert or update on public.inventory_areas for each row execute function app_hidden.inventory_metadata_scope();
create trigger inventory_metadata_scope before insert or update on public.inventory_sub_areas for each row execute function app_hidden.inventory_metadata_scope();
create trigger inventory_metadata_scope before insert or update on public.inventory_subcategories for each row execute function app_hidden.inventory_metadata_scope();

-- Default destinations have stable identity even when their display names are edited.
create function app_hidden.inventory_default_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op='UPDATE' then
    if new.organization_id is distinct from old.organization_id or new.is_default is distinct from old.is_default then
      raise exception 'Organization and default identity are immutable' using errcode='22023'; end if;
    if old.is_default and not new.is_active then raise exception 'Keep the default classification/location active; rename it if needed' using errcode='22023'; end if;
  elsif new.is_default and pg_trigger_depth()=1 and auth.uid() is not null then
    raise exception 'Default identity is managed by the system' using errcode='42501';
  end if;
  return new;
end $$;
create trigger inventory_default_guard before insert or update on public.inventory_categories for each row execute function app_hidden.inventory_default_guard();
create trigger inventory_default_guard before insert or update on public.inventory_areas for each row execute function app_hidden.inventory_default_guard();
create unique index inventory_categories_default_idx on public.inventory_categories(organization_id) where is_default;
create unique index inventory_areas_default_idx on public.inventory_areas(venue_id) where is_default;

create function app_hidden.inventory_item_v2_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op='UPDATE' or tg_op='INSERT' then
    perform pg_advisory_xact_lock(hashtextextended(new.venue_id::text,0));
  end if;
  if tg_op='UPDATE' and new.venue_id is distinct from old.venue_id then raise exception 'Venue is immutable' using errcode='22023'; end if;
  select organization_id into new.organization_id from public.venues where id=new.venue_id;
  if new.category_id is null then select id into new.category_id from public.inventory_categories where organization_id=new.organization_id and is_default; end if;
  if (tg_op='INSERT' or new.unit_cost_usd is distinct from old.unit_cost_usd)
    and new.unit_cost_usd is not null and (new.unit_cost_usd<0 or new.unit_cost_usd::text in ('NaN','Infinity','-Infinity'))
  then raise exception 'Use a finite, nonnegative unit cost' using errcode='22023'; end if;
  if tg_op='INSERT' and new.unit is not null and new.count_unit='Each' then
    new.count_unit:=app_hidden.inventory_normalize_unit(new.unit);
    if new.count_unit='Custom' then new.custom_count_unit:=new.unit; end if;
  end if;
  if tg_op='UPDATE' and exists(select 1 from public.inventory_stock where inventory_item_id=old.id and quantity is not null and quantity<>0)
    and (new.count_unit is distinct from old.count_unit or new.custom_count_unit is distinct from old.custom_count_unit or new.size_amount is distinct from old.size_amount or new.size_unit is distinct from old.size_unit)
  then raise exception 'Create a separate item variant, or correct balances to zero before changing size or count unit' using errcode='22023'; end if;
  return new;
end $$;
create trigger inventory_item_v2_guard before insert or update on public.inventory_items for each row execute function app_hidden.inventory_item_v2_guard();
create function app_hidden.inventory_item_archive_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then raise exception 'Make this inventory item inactive to preserve its stock and history' using errcode='42501'; end if;
  return old;
end $$;
create trigger inventory_item_archive_only before delete on public.inventory_items for each row execute function app_hidden.inventory_item_archive_only();

create function app_hidden.inventory_assert_manager(p_venue uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_venue is null or auth.uid() is null or not app_hidden.has_venue_role(p_venue,array['venue_manager','organization_owner','organization_admin']::public.app_role[]) then
    raise exception 'Only a venue manager or organization admin can change this inventory' using errcode='42501';
  end if;
end $$;
revoke all on function app_hidden.inventory_assert_manager(uuid) from public,anon,authenticated;

create function app_hidden.inventory_write_history(p_stock uuid,p_action text,p_old numeric,p_new numeric,p_reason text,p_notes text,p_ref uuid,p_type text)
returns void language sql security definer set search_path = '' as $$
insert into public.inventory_history(organization_id,venue_id,inventory_item_id,stock_id,area_id,sub_area_id,
item_name,location_name,count_unit,action_type,previous_quantity,quantity_change,new_quantity,unit_cost_snapshot,reason,notes,reference_id,reference_type,performed_by)
select s.organization_id,s.venue_id,i.id,s.id,s.area_id,s.sub_area_id,i.name,
a.name||coalesce(' / '||sa.name,''),case when i.count_unit='Custom' then i.custom_count_unit else i.count_unit end,
p_action,p_old,p_new-p_old,p_new,i.unit_cost_usd,p_reason,p_notes,p_ref,p_type,auth.uid()
from public.inventory_stock s join public.inventory_items i on i.id=s.inventory_item_id
join public.inventory_areas a on a.id=s.area_id left join public.inventory_sub_areas sa on sa.id=s.sub_area_id where s.id=p_stock;
$$;
revoke all on function app_hidden.inventory_write_history(uuid,text,numeric,numeric,text,text,uuid,text) from public,anon,authenticated;
-- Opening balances explicitly identify migration, rather than pretending a physical count occurred.
do $$ declare r record; begin
  for r in select id,quantity from public.inventory_stock loop
    perform app_hidden.inventory_write_history(r.id,'ADJUSTMENT',null,r.quantity,'Migrated opening balance',null,null,'migration');
  end loop;
end $$;

create function app_hidden.inventory_stock_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at:=now();
  if new.quantity is distinct from old.quantity then new.version:=old.version+1; end if;
  return new;
end $$;
create trigger inventory_stock_version before update on public.inventory_stock for each row execute function app_hidden.inventory_stock_version();
-- Even zero/unknown balances have a counting definition. Invalidate open snapshots if
-- their size/count unit changes, so a Bottle count cannot be applied as Case stock.
create function app_hidden.inventory_definition_version() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.count_unit is distinct from old.count_unit or new.custom_count_unit is distinct from old.custom_count_unit
    or new.size_amount is distinct from old.size_amount or new.size_unit is distinct from old.size_unit then
    update public.inventory_stock set version=version+1 where inventory_item_id=new.id;
  end if;
  return new;
end $$;
create trigger inventory_definition_version after update of count_unit,custom_count_unit,size_amount,size_unit
  on public.inventory_items for each row execute function app_hidden.inventory_definition_version();
-- Legacy quantity remains a compatibility projection; any unknown location keeps total unknown.
create function app_hidden.inventory_sync_total() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.inventory_items set quantity=(select case when bool_or(quantity is null) then null else sum(quantity) end
    from public.inventory_stock where inventory_item_id=new.inventory_item_id) where id=new.inventory_item_id;
  return new;
end $$;
create trigger inventory_sync_total after insert or update of quantity on public.inventory_stock for each row execute function app_hidden.inventory_sync_total();
create function app_hidden.inventory_legacy_quantity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a uuid; s uuid; prev numeric; others numeric;
begin
  if pg_trigger_depth()>1 then return new; end if;
  select id into a from public.inventory_areas where venue_id=new.venue_id and is_default;
  if tg_op='INSERT' then
    insert into public.inventory_stock(organization_id,venue_id,inventory_item_id,area_id,quantity)
    values(new.organization_id,new.venue_id,new.id,a,coalesce(new.quantity,0)) returning id into s;
    if new.quantity is not null then perform app_hidden.inventory_write_history(s,'ADJUSTMENT',0,new.quantity,'Opening balance',null,null,'opening'); end if;
  elsif new.quantity is distinct from old.quantity then
    perform app_hidden.inventory_assert_manager(new.venue_id);
    perform pg_advisory_xact_lock(hashtextextended(new.venue_id::text,0));
    select id,quantity into s,prev from public.inventory_stock where inventory_item_id=new.id and area_id=a and sub_area_id is null for update;
    select coalesce(sum(quantity),0) into others from public.inventory_stock where inventory_item_id=new.id and id<>s;
    update public.inventory_stock set quantity=new.quantity-others where id=s;
    perform app_hidden.inventory_write_history(s,'ADJUSTMENT',prev,new.quantity-others,'Legacy quantity correction',null,null,'legacy');
  end if;
  return new;
end $$;
create trigger inventory_legacy_quantity after insert or update of quantity on public.inventory_items for each row execute function app_hidden.inventory_legacy_quantity();

create function public.inventory_set_stock(p_item uuid,p_area uuid,p_sub_area uuid default null,p_par numeric default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items; a public.inventory_areas; sid uuid;
begin
  select * into i from public.inventory_items where id=p_item;
  perform app_hidden.inventory_assert_manager(i.venue_id);
  perform pg_advisory_xact_lock(hashtextextended(i.venue_id::text,0));
  select * into i from public.inventory_items where id=p_item;
  if p_par is not null and (p_par<0 or p_par::text in ('NaN','Infinity','-Infinity') or p_par<>round(p_par,4)) then
    raise exception 'Use a nonnegative par with at most four decimal places' using errcode='22023'; end if;
  select * into a from public.inventory_areas where id=p_area and venue_id=i.venue_id and is_active;
  if not i.is_active or a.id is null or (p_sub_area is not null and not exists(select 1 from public.inventory_sub_areas where id=p_sub_area and area_id=a.id and is_active)) then
    raise exception 'Choose an active item and location in this venue' using errcode='22023'; end if;
  insert into public.inventory_stock(organization_id,venue_id,inventory_item_id,area_id,sub_area_id,quantity,par_level)
  values(i.organization_id,i.venue_id,i.id,a.id,p_sub_area,0,p_par)
  on conflict(inventory_item_id,area_id,sub_area_id) do update set par_level=excluded.par_level returning id into sid;
  return sid;
end $$;

create function public.inventory_apply_action(p_stock uuid,p_action text,p_quantity numeric,p_reason text default null,
  p_notes text default null,p_destination uuid default null,p_operation_id uuid default gen_random_uuid())
returns uuid language plpgsql security definer set search_path = '' as $$
declare s public.inventory_stock; d public.inventory_stock; nextq numeric; prior app_hidden.inventory_operations; payload jsonb;
begin
  select * into s from public.inventory_stock where id=p_stock;
  perform app_hidden.inventory_assert_manager(s.venue_id);
  perform pg_advisory_xact_lock(hashtextextended(s.venue_id::text,0));
  payload:=jsonb_build_array(p_stock,p_action,p_quantity,p_reason,p_notes,p_destination);
  select * into prior from app_hidden.inventory_operations where id=p_operation_id;
  if prior.id is not null then
    if prior.user_id<>auth.uid() or prior.payload<>payload then raise exception 'Operation ID already used' using errcode='22023'; end if;
    return prior.result_id;
  end if;
  select * into s from public.inventory_stock where id=p_stock for update;
  if not exists(select 1 from public.inventory_items where id=s.inventory_item_id and is_active)
    or not exists(select 1 from public.inventory_areas where id=s.area_id and is_active)
    or (s.sub_area_id is not null and not exists(select 1 from public.inventory_sub_areas where id=s.sub_area_id and is_active))
  then raise exception 'Item or location is inactive' using errcode='22023'; end if;
  if p_quantity is null or p_quantity::text in ('NaN','Infinity','-Infinity') or p_quantity<0 or p_quantity<>round(p_quantity,4) then raise exception 'Use a nonnegative quantity with at most four decimal places' using errcode='22023'; end if;
  if p_action is null or p_action not in ('COUNT','RECEIVE','WASTE','ADJUSTMENT','TRANSFER') then raise exception 'Invalid inventory action' using errcode='22023'; end if;
  if p_action in ('RECEIVE','WASTE','TRANSFER') and p_quantity<=0 then raise exception 'Quantity must be greater than zero' using errcode='22023'; end if;
  if p_action in ('WASTE','ADJUSTMENT') and coalesce(length(trim(p_reason)),0)=0 then raise exception 'A reason is required' using errcode='22023'; end if;
  if s.quantity is null and p_action not in ('COUNT','ADJUSTMENT') then raise exception 'Count this location before changing its stock' using errcode='22023'; end if;
  nextq:=case p_action when 'RECEIVE' then s.quantity+p_quantity when 'WASTE' then s.quantity-p_quantity when 'TRANSFER' then s.quantity-p_quantity else p_quantity end;
  if nextq<0 then raise exception 'Insufficient stock; negative inventory is not allowed' using errcode='22023'; end if;
  if p_action='TRANSFER' then
    select * into d from public.inventory_stock where id=p_destination for update;
    if d.id is null or d.id=s.id or d.venue_id<>s.venue_id or d.inventory_item_id<>s.inventory_item_id or d.quantity is null
      or not exists(select 1 from public.inventory_areas where id=d.area_id and is_active)
      or (d.sub_area_id is not null and not exists(select 1 from public.inventory_sub_areas where id=d.sub_area_id and is_active))
    then raise exception 'Choose another counted, active location for the same item in this venue' using errcode='22023'; end if;
    update public.inventory_stock set quantity=nextq where id=s.id;
    update public.inventory_stock set quantity=d.quantity+p_quantity where id=d.id;
    perform app_hidden.inventory_write_history(s.id,'TRANSFER_OUT',s.quantity,nextq,p_reason,p_notes,p_operation_id,'transfer');
    perform app_hidden.inventory_write_history(d.id,'TRANSFER_IN',d.quantity,d.quantity+p_quantity,p_reason,p_notes,p_operation_id,'transfer');
  else
    update public.inventory_stock set quantity=nextq where id=s.id;
    perform app_hidden.inventory_write_history(s.id,p_action,s.quantity,nextq,p_reason,p_notes,p_operation_id,'action');
  end if;
  insert into app_hidden.inventory_operations values(p_operation_id,s.venue_id,auth.uid(),payload,s.id);
  return s.id;
end $$;

create function public.inventory_start_count(p_venue uuid,p_type text default 'full',p_area uuid default null,
 p_category uuid default null,p_subcategory uuid default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare cid uuid; org uuid;
begin
  perform app_hidden.inventory_assert_manager(p_venue);
  perform pg_advisory_xact_lock(hashtextextended(p_venue::text,0));
  select organization_id into org from public.venues where id=p_venue;
  if (p_area is not null and not exists(select 1 from public.inventory_areas where id=p_area and venue_id=p_venue and is_active))
    or (p_category is not null and not exists(select 1 from public.inventory_categories where id=p_category and organization_id=org and is_active))
    or (p_subcategory is not null and not exists(select 1 from public.inventory_subcategories where id=p_subcategory and organization_id=org and (p_category is null or category_id=p_category) and is_active))
  then raise exception 'Invalid count scope' using errcode='22023'; end if;
  insert into public.inventory_counts(organization_id,venue_id,area_id,category_id,subcategory_id,count_type,started_by,notes)
  values(org,p_venue,p_area,p_category,p_subcategory,p_type,auth.uid(),p_notes) returning id into cid;
  insert into public.inventory_count_items(organization_id,venue_id,count_id,inventory_item_id,stock_id,item_name,location_name,count_unit,size_label,previous_quantity,stock_version,unit_cost_snapshot)
  select org,p_venue,cid,i.id,s.id,i.name,a.name||coalesce(' / '||sa.name,''),
    case when i.count_unit='Custom' then i.custom_count_unit else i.count_unit end,
    case when i.size_amount is not null then i.size_amount::text||' '||i.size_unit end,s.quantity,s.version,i.unit_cost_usd
  from public.inventory_stock s join public.inventory_items i on i.id=s.inventory_item_id
  join public.inventory_areas a on a.id=s.area_id left join public.inventory_sub_areas sa on sa.id=s.sub_area_id
  where s.venue_id=p_venue and i.is_active and a.is_active and (sa.id is null or sa.is_active)
    and (p_area is null or s.area_id=p_area) and (p_category is null or i.category_id=p_category)
    and (p_subcategory is null or i.subcategory_id=p_subcategory);
  if not found then raise exception 'No active stock locations match this count' using errcode='22023'; end if;
  return cid;
end $$;

create function public.inventory_save_count(p_count uuid,p_values jsonb default '[]',p_complete boolean default false,p_cancel boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.inventory_counts; v jsonb; q numeric; r record;
begin
  select * into c from public.inventory_counts where id=p_count;
  perform app_hidden.inventory_assert_manager(c.venue_id);
  perform pg_advisory_xact_lock(hashtextextended(c.venue_id::text,0));
  select * into c from public.inventory_counts where id=p_count for update;
  if c.status='completed' and p_complete then return; end if;
  if c.status='cancelled' and p_cancel then return; end if;
  if c.status in ('completed','cancelled') then raise exception 'This count is already closed' using errcode='22023'; end if;
  if p_cancel then update public.inventory_counts set status='cancelled',completed_at=now(),completed_by=auth.uid() where id=c.id; return; end if;
  if jsonb_typeof(p_values)<>'array' then raise exception 'Invalid count values' using errcode='22023'; end if;
  for v in select value from jsonb_array_elements(p_values) loop
    q:=(v->>'quantity')::numeric;
    if q is not null and (q<0 or q::text in ('NaN','Infinity','-Infinity') or q<>round(q,4)) then raise exception 'Invalid counted quantity' using errcode='22023'; end if;
    update public.inventory_count_items set counted_quantity=q,counted_by=case when q is not null then auth.uid() end,counted_at=case when q is not null then now() end
    where id=(v->>'id')::uuid and count_id=c.id;
    if not found then raise exception 'Count row does not belong to this count' using errcode='22023'; end if;
  end loop;
  if not p_complete then update public.inventory_counts set status='in_progress' where id=c.id; return; end if;
  if not exists(select 1 from public.inventory_count_items where count_id=c.id and counted_quantity is not null)
    or (c.count_type='full' and exists(select 1 from public.inventory_count_items where count_id=c.id and counted_quantity is null))
  then raise exception 'Count every location for a full count, or use a partial count' using errcode='22023'; end if;
  -- Lock snapshot rows and their stock before checking versions; no partial application can
  -- slip through an unrelated stock deletion or a legacy quantity edit.
  perform 1 from public.inventory_stock s join public.inventory_count_items ci on ci.stock_id=s.id
    where ci.count_id=c.id and ci.counted_quantity is not null order by s.id for update of s;
  for r in select ci.*,s.quantity as live_quantity,s.version as live_version,i.is_active as item_active,a.is_active as area_active,
    coalesce(sa.is_active,true) as sub_active
    from public.inventory_count_items ci left join public.inventory_stock s on s.id=ci.stock_id
    left join public.inventory_items i on i.id=s.inventory_item_id left join public.inventory_areas a on a.id=s.area_id
    left join public.inventory_sub_areas sa on sa.id=s.sub_area_id
    where ci.count_id=c.id and ci.counted_quantity is not null order by ci.stock_id loop
    if r.stock_id is null or not coalesce(r.item_active and r.area_active and r.sub_active,false) then raise exception 'An item or location was removed or made inactive; cancel and start a new count' using errcode='22023'; end if;
    if r.live_version<>r.stock_version then raise exception 'Stock changed after this count started; cancel and recount to avoid overwriting it' using errcode='40001'; end if;
    update public.inventory_stock set quantity=r.counted_quantity where id=r.stock_id;
    perform app_hidden.inventory_write_history(r.stock_id,'COUNT',r.previous_quantity,r.counted_quantity,'Physical count',c.notes,c.id,'count');
    -- Count valuation must use its start-time cost snapshot, even if the master cost changed.
    update public.inventory_history set unit_cost_snapshot=r.unit_cost_snapshot where reference_id=c.id and stock_id=r.stock_id and action_type='COUNT';
  end loop;
  update public.inventory_counts set status='completed',completed_at=now(),completed_by=auth.uid() where id=c.id;
end $$;

create function public.inventory_dashboard(p_venue uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
select jsonb_build_object('uncounted',(
  select count(*) from public.inventory_count_items ci join public.inventory_counts c on c.id=ci.count_id
  where c.venue_id=p_venue and c.status in ('draft','in_progress') and ci.counted_quantity is null
));
$$;
revoke all on function public.inventory_dashboard(uuid) from public,anon;
grant execute on function public.inventory_dashboard(uuid) to authenticated;

-- Restrict table access even on projects with broad default grants. History and stock are
-- readable through RLS; checked functions are the only client write surface.
do $$ declare t text; begin
  foreach t in array array['inventory_categories','inventory_subcategories'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('alter table public.%I force row level security',t);
    execute format('revoke all on public.%I from anon,authenticated',t);
    execute format('grant select,insert,update on public.%I to authenticated',t);
    execute format('create policy inventory_read on public.%I for select to authenticated using(app_hidden.is_org_member(organization_id))',t);
    execute format('create policy inventory_insert on public.%I for insert to authenticated with check(app_hidden.has_org_role(organization_id,array[''organization_owner'',''organization_admin'']::public.app_role[]))',t);
    execute format('create policy inventory_update on public.%I for update to authenticated using(app_hidden.has_org_role(organization_id,array[''organization_owner'',''organization_admin'']::public.app_role[])) with check(app_hidden.has_org_role(organization_id,array[''organization_owner'',''organization_admin'']::public.app_role[]))',t);
  end loop;
  foreach t in array array['inventory_areas','inventory_sub_areas','inventory_stock','inventory_counts','inventory_count_items','inventory_history'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('alter table public.%I force row level security',t);
    execute format('revoke all on public.%I from anon,authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('create policy inventory_read on public.%I for select to authenticated using(app_hidden.is_venue_member(venue_id))',t);
  end loop;
  foreach t in array array['inventory_areas','inventory_sub_areas'] loop
    execute format('grant insert,update on public.%I to authenticated',t);
    execute format('create policy inventory_insert on public.%I for insert to authenticated with check(app_hidden.has_venue_role(venue_id,array[''venue_manager'',''organization_owner'',''organization_admin'']::public.app_role[]))',t);
    execute format('create policy inventory_update on public.%I for update to authenticated using(app_hidden.has_venue_role(venue_id,array[''venue_manager'',''organization_owner'',''organization_admin'']::public.app_role[])) with check(app_hidden.has_venue_role(venue_id,array[''venue_manager'',''organization_owner'',''organization_admin'']::public.app_role[]))',t);
  end loop;
end $$;
revoke all on function public.inventory_set_stock(uuid,uuid,uuid,numeric) from public,anon;
revoke all on function public.inventory_apply_action(uuid,text,numeric,text,text,uuid,uuid) from public,anon;
revoke all on function public.inventory_start_count(uuid,text,uuid,uuid,uuid,text) from public,anon;
revoke all on function public.inventory_save_count(uuid,jsonb,boolean,boolean) from public,anon;
grant execute on function public.inventory_set_stock(uuid,uuid,uuid,numeric),public.inventory_apply_action(uuid,text,numeric,text,text,uuid,uuid),
public.inventory_start_count(uuid,text,uuid,uuid,uuid,text),public.inventory_save_count(uuid,jsonb,boolean,boolean) to authenticated;

create index inventory_categories_org_idx on public.inventory_categories(organization_id);
create index inventory_subcategories_org_idx on public.inventory_subcategories(organization_id);
create index inventory_subcategories_category_idx on public.inventory_subcategories(category_id);
create index inventory_items_category_idx on public.inventory_items(category_id);
create index inventory_items_subcategory_idx on public.inventory_items(subcategory_id);
create index inventory_areas_org_idx on public.inventory_areas(organization_id);
create index inventory_sub_areas_venue_idx on public.inventory_sub_areas(venue_id);
create index inventory_sub_areas_org_idx on public.inventory_sub_areas(organization_id);
create index inventory_stock_venue_idx on public.inventory_stock(venue_id);
create index inventory_stock_org_idx on public.inventory_stock(organization_id);
create index inventory_stock_area_idx on public.inventory_stock(area_id);
create index inventory_stock_sub_area_idx on public.inventory_stock(sub_area_id);
create index inventory_counts_venue_started_idx on public.inventory_counts(venue_id,started_at desc);
create index inventory_counts_org_idx on public.inventory_counts(organization_id);
create index inventory_counts_area_idx on public.inventory_counts(area_id);
create index inventory_counts_category_idx on public.inventory_counts(category_id);
create index inventory_counts_subcategory_idx on public.inventory_counts(subcategory_id);
create index inventory_counts_started_by_idx on public.inventory_counts(started_by);
create index inventory_counts_completed_by_idx on public.inventory_counts(completed_by);
create index inventory_count_items_venue_idx on public.inventory_count_items(venue_id);
create index inventory_count_items_org_idx on public.inventory_count_items(organization_id);
create index inventory_count_items_item_idx on public.inventory_count_items(inventory_item_id);
create index inventory_count_items_stock_idx on public.inventory_count_items(stock_id);
create index inventory_count_items_counted_by_idx on public.inventory_count_items(counted_by);
create index inventory_history_venue_created_idx on public.inventory_history(venue_id,created_at desc);
create index inventory_history_org_idx on public.inventory_history(organization_id);
create index inventory_history_item_created_idx on public.inventory_history(inventory_item_id,created_at desc);
create index inventory_history_stock_idx on public.inventory_history(stock_id);
create index inventory_history_area_idx on public.inventory_history(area_id);
create index inventory_history_sub_area_idx on public.inventory_history(sub_area_id);
create index inventory_history_performed_by_idx on public.inventory_history(performed_by);
create index inventory_operations_venue_idx on app_hidden.inventory_operations(venue_id);
-- Trigger functions are internal implementation details, never API entry points.
revoke all on function app_hidden.inventory_seed_new_org(),app_hidden.inventory_seed_new_venue(),
  app_hidden.inventory_metadata_scope(),app_hidden.inventory_default_guard(),app_hidden.inventory_item_v2_guard(),
  app_hidden.inventory_item_archive_only(),app_hidden.inventory_stock_version(),app_hidden.inventory_sync_total(),
  app_hidden.inventory_legacy_quantity(),app_hidden.inventory_normalize_unit(text),app_hidden.inventory_definition_version() from public,anon,authenticated;
commit;
