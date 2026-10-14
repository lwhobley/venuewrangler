-- Floor Plan Studio: custom objects (stage, bar, dance floor, ...) stored beside the table
-- layout. A separate column keeps `layout` (tables) untouched. Existing rows get an empty
-- array. Shape of each object is validated by the app; the database only requires an array.
-- RLS on the table already covers this column (managers write, venue members read).

alter table public.floor_plan_studio_layouts
  add column if not exists objects jsonb not null default '[]'::jsonb;

alter table public.floor_plan_studio_layouts
  drop constraint if exists floor_plan_studio_layouts_objects_is_array;

alter table public.floor_plan_studio_layouts
  add constraint floor_plan_studio_layouts_objects_is_array
  check (jsonb_typeof(objects) = 'array');
