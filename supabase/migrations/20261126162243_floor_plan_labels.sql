-- Non-seatable labelled areas drawn on a floor plan (stage, bars, DJ booth, ...).
-- Each element: {"text": string, "x": number, "y": number, "width": number, "height": number}
-- in the same plan coordinates as floor_tables (x/y is the top-left corner).
alter table public.floor_plans
  add column if not exists labels jsonb not null default '[]'::jsonb;

alter table public.floor_plans drop constraint if exists floor_plans_labels_is_array;
alter table public.floor_plans
  add constraint floor_plans_labels_is_array check (jsonb_typeof(labels) = 'array');
