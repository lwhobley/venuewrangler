-- Self-contained TAP assertions: works with pg_prove in CI and stock psql locally.
begin;
create temporary sequence inventory_assertions;
grant usage,select on sequence inventory_assertions to authenticated,anon;
create function pg_temp.inv_ok(condition boolean,label text) returns text language plpgsql as $$
begin return (case when condition is true then 'ok ' else 'not ok ' end)||nextval('pg_temp.inventory_assertions')||' - '||label; end $$;
create function pg_temp.inv_error(statement text,expected text) returns boolean language plpgsql as $$
begin execute statement; return false; exception when others then return sqlstate=expected; end $$;
create temporary table inventory_test_ids(key text primary key,id uuid);
grant all on inventory_test_ids to authenticated;
create function pg_temp.inv_id(k text) returns uuid language sql as $$select id from pg_temp.inventory_test_ids where key=k$$;

insert into auth.users(id,email) values
('81000000-0000-0000-0000-000000000001','inv-owner@test.example'),
('81000000-0000-0000-0000-000000000002','inv-manager@test.example'),
('81000000-0000-0000-0000-000000000003','inv-staff@test.example'),
('81000000-0000-0000-0000-000000000004','inv-other@test.example');
insert into public.organizations(id,name) values
('82000000-0000-0000-0000-000000000001','Inventory A'),('82000000-0000-0000-0000-000000000002','Inventory B');
insert into public.venues(id,organization_id,name) values
('83000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','Main'),
('83000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-000000000002','Other'),
('83000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-000000000001','Same org, other venue');
insert into public.memberships(user_id,organization_id,venue_id,role) values
('81000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001',null,'organization_owner'),
('81000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','venue_manager'),
('81000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','staff'),
('81000000-0000-0000-0000-000000000004','82000000-0000-0000-0000-000000000002',null,'organization_owner');
insert into inventory_test_ids select 'liquor',id from public.inventory_categories where organization_id='82000000-0000-0000-0000-000000000001' and name='Liquor';
insert into inventory_test_ids select 'vodka',id from public.inventory_subcategories where category_id=pg_temp.inv_id('liquor') and name='Vodka';
insert into public.inventory_areas(id,organization_id,venue_id,name) values
('84000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','Main Bar'),
('84000000-0000-0000-0000-000000000002','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','Liquor Room'),
('84000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000003','Other venue bar');
insert into public.inventory_sub_areas(id,organization_id,venue_id,area_id,name)
values('85000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001','Speed Rail');

set local role authenticated;
set local "request.jwt.claim.sub"='81000000-0000-0000-0000-000000000002';
insert into public.inventory_items(id,venue_id,name,quantity,unit,unit_cost_usd,category_id,subcategory_id,size_amount,size_unit,count_unit)
values('86000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','Tito''s Vodka',6.5,'bottle',24.50,pg_temp.inv_id('liquor'),pg_temp.inv_id('vodka'),1,'L','Bottle');
insert into inventory_test_ids select 'general',id from public.inventory_stock where inventory_item_id='86000000-0000-0000-0000-000000000001';
select pg_temp.inv_ok((select quantity=6.5 from public.inventory_stock where id=pg_temp.inv_id('general')),'legacy item insert preserves decimal opening stock');
select pg_temp.inv_ok((select count(*)=17 from public.inventory_categories where organization_id='82000000-0000-0000-0000-000000000001'),'defaults seed all restaurant categories for new organizations');
select pg_temp.inv_ok(pg_temp.inv_error($q$update public.inventory_items set subcategory_id=(select id from public.inventory_subcategories where name='Red' limit 1) where id='86000000-0000-0000-0000-000000000001'$q$,'23503'),'subcategory must belong to chosen category');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000003')$q$,'22023'),'stock cannot use another venue area');
insert into inventory_test_ids values('bar',public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',null,8)),
('room',public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000002',null,12));
select pg_temp.inv_ok(public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',null,8)=pg_temp.inv_id('bar'),'null sub-area stock position is unique');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000002','85000000-0000-0000-0000-000000000001')$q$,'22023'),'sub-area must belong to selected area');
select public.inventory_apply_action(pg_temp.inv_id('general'),'ADJUSTMENT',0,'Move opening stock into assigned locations');
select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',6.5);
select public.inventory_apply_action(pg_temp.inv_id('room'),'RECEIVE',18);
insert into inventory_test_ids values('count',public.inventory_start_count('83000000-0000-0000-0000-000000000001','full','84000000-0000-0000-0000-000000000001',pg_temp.inv_id('liquor'),pg_temp.inv_id('vodka')));
select pg_temp.inv_ok((select count(*)=1 from public.inventory_count_items where count_id=pg_temp.inv_id('count')),'count area/category/subcategory scope selects only matching stock');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('count'),'[]',true)$q$,'22023'),'full count cannot complete with an uncounted position');
select public.inventory_save_count(pg_temp.inv_id('count'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',4.5)) from public.inventory_count_items where count_id=pg_temp.inv_id('count')),true);
select pg_temp.inv_ok((select quantity=4.5 from public.inventory_stock where id=pg_temp.inv_id('bar')),'count completion updates decimal stock');
select pg_temp.inv_ok((select previous_quantity=6.5 and variance_quantity=-2 and variance_value=-49 from public.inventory_count_items where count_id=pg_temp.inv_id('count')),'count keeps previous quantity and computes exact quantity/dollar variance');
select pg_temp.inv_ok((select status='completed' and completed_by='81000000-0000-0000-0000-000000000002' and completed_at is not null from public.inventory_counts where id=pg_temp.inv_id('count')),'count records completing actor and time');
select pg_temp.inv_ok((select count(*)=1 from public.inventory_history where reference_id=pg_temp.inv_id('count') and action_type='COUNT'),'count creates one history entry');
select public.inventory_save_count(pg_temp.inv_id('count'),'[]',true);
select pg_temp.inv_ok((select count(*)=1 from public.inventory_history where reference_id=pg_temp.inv_id('count') and action_type='COUNT'),'completed count retry cannot apply twice');
select public.inventory_apply_action(pg_temp.inv_id('room'),'RECEIVE',12,null,null,null,'87000000-0000-0000-0000-000000000001');
select public.inventory_apply_action(pg_temp.inv_id('room'),'RECEIVE',12,null,null,null,'87000000-0000-0000-0000-000000000001');
select pg_temp.inv_ok((select quantity=30 from public.inventory_stock where id=pg_temp.inv_id('room')),'receiving is atomic and operation-ID retry does not double receive');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('room'),'RECEIVE',13,null,null,null,'87000000-0000-0000-0000-000000000001')$q$,'22023'),'operation ID cannot be reused with changed input');
select public.inventory_apply_action(pg_temp.inv_id('room'),'TRANSFER',4,null,null,pg_temp.inv_id('bar'),'87000000-0000-0000-0000-000000000002');
select pg_temp.inv_ok((select quantity=26 from public.inventory_stock where id=pg_temp.inv_id('room')) and (select quantity=8.5 from public.inventory_stock where id=pg_temp.inv_id('bar')),'transfer subtracts and adds the same decimal quantity');
select pg_temp.inv_ok((select count(*)=2 from public.inventory_history where reference_id='87000000-0000-0000-0000-000000000002' and action_type in ('TRANSFER_OUT','TRANSFER_IN')),'transfer creates both linked history records');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('room'),'TRANSFER',100,null,null,pg_temp.inv_id('bar'))$q$,'22023'),'transfer rejects insufficient source stock');
select pg_temp.inv_ok((select quantity=26 from public.inventory_stock where id=pg_temp.inv_id('room')) and (select quantity=8.5 from public.inventory_stock where id=pg_temp.inv_id('bar')),'failed transfer changes neither location');
select public.inventory_apply_action(pg_temp.inv_id('bar'),'WASTE',0.5,'Spill');
select pg_temp.inv_ok((select quantity=8 from public.inventory_stock where id=pg_temp.inv_id('bar')),'waste subtracts a fractional bottle');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'WASTE',1)$q$,'22023'),'waste requires a reason');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'ADJUSTMENT',2)$q$,'22023'),'adjustments require a reason');
select pg_temp.inv_ok((select quantity=34 from public.inventory_items where id='86000000-0000-0000-0000-000000000001'),'master compatibility total sums same item across locations');
select pg_temp.inv_ok((select sum(s.quantity*i.unit_cost_usd)=833 from public.inventory_stock s join public.inventory_items i on i.id=s.inventory_item_id where i.id='86000000-0000-0000-0000-000000000001'),'inventory value uses exact NUMERIC arithmetic');
select pg_temp.inv_ok(pg_temp.inv_error($q$update public.inventory_items set quantity=0 where id='86000000-0000-0000-0000-000000000001'$q$,'22023'),'legacy quantity edit cannot drive a location negative');
select pg_temp.inv_ok((select quantity=34 from public.inventory_items where id='86000000-0000-0000-0000-000000000001'),'rejected legacy quantity edit leaves the total unchanged');
insert into inventory_test_ids values('stale',public.inventory_start_count('83000000-0000-0000-0000-000000000001','full','84000000-0000-0000-0000-000000000001'));
select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',1);
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('stale'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',0)) from public.inventory_count_items where count_id=pg_temp.inv_id('stale')),true)$q$,'40001'),'stale count cannot overwrite stock changed during counting');
select pg_temp.inv_ok((select quantity=9 from public.inventory_stock where id=pg_temp.inv_id('bar')),'stale count transaction preserves current stock');
select public.inventory_save_count(pg_temp.inv_id('stale'),'[]',false,true);
select pg_temp.inv_ok((select status='cancelled' from public.inventory_counts where id=pg_temp.inv_id('stale')),'count can be cancelled without stock updates');
insert into inventory_test_ids values('partial',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial'));
select public.inventory_save_count(pg_temp.inv_id('partial'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',2.25)) from public.inventory_count_items where count_id=pg_temp.inv_id('partial') and stock_id=pg_temp.inv_id('bar')),true);
select pg_temp.inv_ok((select quantity=2.25 from public.inventory_stock where id=pg_temp.inv_id('bar')) and (select quantity=26 from public.inventory_stock where id=pg_temp.inv_id('room')),'partial count leaves blank locations unchanged');
select public.inventory_apply_action(pg_temp.inv_id('bar'),'ADJUSTMENT',0,'Empty shelf');
select pg_temp.inv_ok((select quantity=0 from public.inventory_stock where id=pg_temp.inv_id('bar')),'zero quantity is a valid adjustment');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',null,'NaN')$q$,'22023'),'par rejects nonfinite input');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_set_stock('86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000001',null,1.12345)$q$,'22023'),'par rejects silent decimal rounding');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('room'),'RECEIVE',1.12345)$q$,'22023'),'receiving rejects quantities beyond four decimals');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('room'),'TRANSFER',1,null,null,pg_temp.inv_id('room'))$q$,'22023'),'transfer rejects same source and destination');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'WASTE',1,'Spill')$q$,'22023'),'waste cannot create negative stock');
insert into public.inventory_items(id,venue_id,name,quantity,count_unit,unit_cost_usd)
values('86000000-0000-0000-0000-000000000002','83000000-0000-0000-0000-000000000001','Chicken',14.25,'Pound',3.20),
('86000000-0000-0000-0000-000000000003','83000000-0000-0000-0000-000000000001','To-go containers',240,'Each',null);
insert into inventory_test_ids select 'chicken',id from public.inventory_stock where inventory_item_id='86000000-0000-0000-0000-000000000002';
insert into inventory_test_ids select 'containers',id from public.inventory_stock where inventory_item_id='86000000-0000-0000-0000-000000000003';
select pg_temp.inv_ok((select quantity=14.25 from public.inventory_stock where id=pg_temp.inv_id('chicken')) and (select quantity=240 from public.inventory_stock where id=pg_temp.inv_id('containers')),'food and non-food use the same decimal stock workflow');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('room'),'TRANSFER',1,null,null,pg_temp.inv_id('chicken'))$q$,'22023'),'transfer cannot change the inventory item');
select pg_temp.inv_ok(pg_temp.inv_error($q$update public.inventory_items set size_amount=750,size_unit='mL' where id='86000000-0000-0000-0000-000000000001'$q$,'22023'),'size cannot silently reinterpret existing stock');
select pg_temp.inv_ok(pg_temp.inv_error($q$update public.inventory_items set unit_cost_usd='NaN' where id='86000000-0000-0000-0000-000000000001'$q$,'22023'),'unit cost rejects nonfinite input');
insert into inventory_test_ids values('cost_snapshot',public.inventory_start_count('83000000-0000-0000-0000-000000000001','full','84000000-0000-0000-0000-000000000002'));
update public.inventory_items set unit_cost_usd=30 where id='86000000-0000-0000-0000-000000000001';
select public.inventory_save_count(pg_temp.inv_id('cost_snapshot'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',25)) from public.inventory_count_items where count_id=pg_temp.inv_id('cost_snapshot')),true);
select pg_temp.inv_ok((select variance_value=-24.50 and unit_cost_snapshot=24.50 from public.inventory_count_items where count_id=pg_temp.inv_id('cost_snapshot')) and (select unit_cost_snapshot=24.50 from public.inventory_history where reference_id=pg_temp.inv_id('cost_snapshot')),'count and history retain starting cost after the master cost changes');
update public.inventory_items set unit_cost_usd=24.50 where id='86000000-0000-0000-0000-000000000001';
insert into inventory_test_ids values('no_cost',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial'));
select public.inventory_save_count(pg_temp.inv_id('no_cost'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',220)) from public.inventory_count_items where count_id=pg_temp.inv_id('no_cost') and stock_id=pg_temp.inv_id('containers')),true);
select pg_temp.inv_ok((select variance_quantity=-20 and variance_value is null from public.inventory_count_items where count_id=pg_temp.inv_id('no_cost') and stock_id=pg_temp.inv_id('containers')),'missing cost preserves quantity variance without inventing dollar value');
-- Simulate an unknown legacy balance and prove a count can establish a baseline.
reset role;
update public.inventory_stock set quantity=null where id=pg_temp.inv_id('containers');
set local role authenticated;
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('containers'),'RECEIVE',1)$q$,'22023'),'unknown stock requires an explicit baseline');
insert into inventory_test_ids values('unknown',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial'));
select public.inventory_save_count(pg_temp.inv_id('unknown'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',240)) from public.inventory_count_items where count_id=pg_temp.inv_id('unknown') and stock_id=pg_temp.inv_id('containers')),true);
select pg_temp.inv_ok((select previous_quantity is null and variance_quantity is null from public.inventory_count_items where count_id=pg_temp.inv_id('unknown') and stock_id=pg_temp.inv_id('containers')) and (select quantity=240 from public.inventory_stock where id=pg_temp.inv_id('containers')),'first baseline count preserves unknown previous quantity');
insert into inventory_test_ids values('draft_a',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial')),
('draft_b',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial'));
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('draft_a'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',0)) from public.inventory_count_items where count_id=pg_temp.inv_id('draft_b')))$q$,'22023'),'count save rejects rows belonging to another count');
select public.inventory_save_count(pg_temp.inv_id('draft_a'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',14.25)) from public.inventory_count_items where count_id=pg_temp.inv_id('draft_a') and stock_id=pg_temp.inv_id('chicken')));
select pg_temp.inv_ok((select status='in_progress' from public.inventory_counts where id=pg_temp.inv_id('draft_a')) and (select quantity=14.25 from public.inventory_stock where id=pg_temp.inv_id('chicken')),'saving draft progress does not mutate stock');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('stale'),'[]',true)$q$,'22023'),'cancelled count cannot later be completed');
insert into public.inventory_items(id,venue_id,name,quantity,count_unit)
values('86000000-0000-0000-0000-000000000004','83000000-0000-0000-0000-000000000001','Empty supply',0,'Each');
insert into inventory_test_ids values('unit_stale',public.inventory_start_count('83000000-0000-0000-0000-000000000001','partial'));
update public.inventory_items set count_unit='Box',size_amount=500,size_unit='count' where id='86000000-0000-0000-0000-000000000004';
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('unit_stale'),(select jsonb_agg(jsonb_build_object('id',id,'quantity',1)) from public.inventory_count_items where count_id=pg_temp.inv_id('unit_stale') and inventory_item_id='86000000-0000-0000-0000-000000000004'),true)$q$,'40001'),'definition change invalidates an open count even when prior stock was zero');
select pg_temp.inv_ok(pg_temp.inv_error($q$insert into public.inventory_categories(organization_id,name,inventory_group) values('82000000-0000-0000-0000-000000000001','Manager taxonomy','Food')$q$,'42501'),'venue manager cannot alter organization-wide taxonomy');
set local "request.jwt.claim.sub"='81000000-0000-0000-0000-000000000001';
select pg_temp.inv_ok(pg_temp.inv_error($q$update public.inventory_categories set organization_id='82000000-0000-0000-0000-000000000002' where id=pg_temp.inv_id('liquor')$q$,'22023'),'taxonomy cannot be moved to another organization');
select pg_temp.inv_ok(pg_temp.inv_error($q$insert into public.inventory_categories(organization_id,name,inventory_group,is_default) values('82000000-0000-0000-0000-000000000001','Forged default','Food',true)$q$,'42501'),'ordinary API callers cannot forge system default identity');
set local "request.jwt.claim.sub"='81000000-0000-0000-0000-000000000002';
update public.inventory_items set is_active=false where id='86000000-0000-0000-0000-000000000001';
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',1)$q$,'22023'),'inactive item rejects new stock actions');
update public.inventory_items set is_active=true where id='86000000-0000-0000-0000-000000000001';
update public.inventory_areas set is_active=false where id='84000000-0000-0000-0000-000000000001';
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',1)$q$,'22023'),'inactive area rejects new stock actions');
update public.inventory_areas set is_active=true where id='84000000-0000-0000-0000-000000000001';
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_start_count('83000000-0000-0000-0000-000000000003')$q$,'42501'),'venue manager cannot count a different venue in the same organization');
select pg_temp.inv_ok(pg_temp.inv_error($q$insert into public.inventory_stock(organization_id,venue_id,inventory_item_id,area_id,quantity) values('82000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','86000000-0000-0000-0000-000000000001','84000000-0000-0000-0000-000000000002',50)$q$,'42501'),'direct stock insertion is forbidden even to managers');
-- CI's broad grants stub must not turn history into a client-writable table: no write policy.
reset role;
grant update,delete on public.inventory_history to authenticated;
set local role authenticated;
update public.inventory_history set reason='Tampered';
delete from public.inventory_history;
select pg_temp.inv_ok(not exists(select 1 from public.inventory_history where reason='Tampered') and exists(select 1 from public.inventory_history),'history cannot be edited or deleted by ordinary authenticated callers');
set local "request.jwt.claim.sub"='81000000-0000-0000-0000-000000000003';
select pg_temp.inv_ok((select count(*)>0 from public.inventory_stock where venue_id='83000000-0000-0000-0000-000000000001'),'staff can read their venue stock');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',1)$q$,'42501'),'staff cannot receive inventory');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_start_count('83000000-0000-0000-0000-000000000001')$q$,'42501'),'staff cannot start a physical count');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_save_count(pg_temp.inv_id('draft_a'),'[]',false,true)$q$,'42501'),'staff cannot cancel a manager count');
set local "request.jwt.claim.sub"='81000000-0000-0000-0000-000000000004';
select pg_temp.inv_ok((select count(*)=0 from public.inventory_stock where venue_id='83000000-0000-0000-0000-000000000001'),'other organization cannot read stock');
select pg_temp.inv_ok((select count(*)=0 from public.inventory_history where venue_id='83000000-0000-0000-0000-000000000001'),'other organization cannot read history');
select pg_temp.inv_ok(pg_temp.inv_error($q$select public.inventory_apply_action(pg_temp.inv_id('bar'),'RECEIVE',1)$q$,'42501'),'other organization cannot write through RPC');
select pg_temp.inv_ok((public.inventory_dashboard('83000000-0000-0000-0000-000000000001')->>'uncounted')::int=0,'dashboard RPC does not disclose another venue count rows');
reset role;
select '1..'||currval('pg_temp.inventory_assertions');
rollback;
