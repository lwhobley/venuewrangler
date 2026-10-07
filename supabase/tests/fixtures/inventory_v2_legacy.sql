-- Only for disposable migration tests. Apply after the original inventory migration,
-- before restaurant_inventory_v2. Never load into a live project.
insert into auth.users(id,email) values('91000000-0000-0000-0000-000000000001','legacy-inventory@test.example');
insert into public.organizations(id,name) values('92000000-0000-0000-0000-000000000001','Legacy Inventory');
insert into public.venues(id,organization_id,name) values('93000000-0000-0000-0000-000000000001','92000000-0000-0000-0000-000000000001','Legacy Venue');
insert into public.memberships(user_id,organization_id,venue_id,role) values('91000000-0000-0000-0000-000000000001','92000000-0000-0000-0000-000000000001',null,'organization_owner');
insert into public.inventory_items(id,venue_id,name,quantity,unit,unit_cost_usd) values
('94000000-0000-0000-0000-000000000001','93000000-0000-0000-0000-000000000001','Legacy Vodka',6.50,'bottle',24.50),
('94000000-0000-0000-0000-000000000002','93000000-0000-0000-0000-000000000001','Legacy Chicken',14.25,'lb',3.20),
('94000000-0000-0000-0000-000000000003','93000000-0000-0000-0000-000000000001','Legacy Containers',240,'sleeve of 20',null),
('94000000-0000-0000-0000-000000000004','93000000-0000-0000-0000-000000000001','Legacy Negative',-2.50,'case',null),
('94000000-0000-0000-0000-000000000005','93000000-0000-0000-0000-000000000001','Legacy Unknown',null,null,null);
