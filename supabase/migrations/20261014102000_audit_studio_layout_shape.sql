-- Validate new writes without deleting or rewriting existing malformed plans.
-- NOT VALID preserves those rows for explicit repair; it still checks every new
-- INSERT/UPDATE. Clients surface them as per-plan errors instead of hiding them.
create function app_hidden.valid_studio_tables(p_layout jsonb) returns boolean
language plpgsql immutable set search_path = '' as $$
declare t jsonb; x double precision; y double precision;
begin
  if p_layout is null or jsonb_typeof(p_layout) <> 'array' then return false; end if;
  for t in select value from jsonb_array_elements(p_layout) loop
    if jsonb_typeof(t) <> 'object' or jsonb_typeof(t->'x') is distinct from 'number'
       or jsonb_typeof(t->'y') is distinct from 'number' then return false; end if;
    x := (t->>'x')::double precision; y := (t->>'y')::double precision;
    if x < 0 or y < 0 or x in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
       or y in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8) then return false; end if;
  end loop;
  return true;
exception when invalid_text_representation or numeric_value_out_of_range then return false;
end;
$$;
alter table public.floor_plan_studio_layouts add constraint studio_tables_shape
  check (app_hidden.valid_studio_tables(layout)) not valid;
alter table public.floor_plan_studio_layouts add constraint studio_dimensions_finite
  check (width_feet not in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
     and depth_feet not in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
     and table_diameter_feet not in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)) not valid;
