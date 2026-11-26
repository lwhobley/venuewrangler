alter table public.floor_plans drop constraint if exists floor_plans_labels_is_array;
alter table public.floor_plans drop column if exists labels;
