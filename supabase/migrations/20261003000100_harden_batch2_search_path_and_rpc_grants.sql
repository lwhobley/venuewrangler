-- Hardening pass for the batch-2 Phase 4 modules (time-clock, media-cleanup, notifications,
-- guests/reservations, floor, pos, chat), following the live security advisor's findings
-- after applying those migrations.

-- 1. Two functions were missing `set search_path`, same class of fix as the earlier
-- harden_try_cast_uuid_search_path / harden_subscription_is_entitled migrations.
create or replace function app_hidden.haversine_distance_m(
  lat1 double precision,
  lng1 double precision,
  lat2 double precision,
  lng2 double precision
) returns double precision
language plpgsql
immutable
set search_path = public
as $$
declare
  r double precision := 6371000.0;
  dlat double precision;
  dlng double precision;
  a double precision;
begin
  dlat := radians(lat2 - lat1);
  dlng := radians(lng2 - lng1);
  a := sin(dlat / 2.0)^2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlng / 2.0)^2;
  return 2.0 * r * asin(least(1.0::double precision, sqrt(a)));
end;
$$;

create or replace function app_hidden.is_safe_storage_deletion_path(
  p_bucket_id text,
  p_object_path text
) returns boolean
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_bucket_id not in ('incident-evidence', 'checklist-evidence', 'staff-documents', 'exports', 'temp-imports', 'chat') then
    return false;
  end if;

  if p_object_path like '%..%' or p_object_path like '/%' or p_object_path like '%//%' then
    return false;
  end if;

  if not (p_object_path ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?[a-zA-Z0-9_\-\.]+$') then
    return false;
  end if;

  return true;
end;
$$;

-- 2. Six SECURITY DEFINER RPCs were created without their own EXECUTE grant narrowed, so
-- Postgres' default grant to PUBLIC left them callable by the `anon` role (each has its own
-- internal has_venue_role/auth.uid() check, so this was not an active bypass, but the advisor
-- correctly flags it as unintended exposure — same class of fix as the column-level grants
-- elsewhere in this schema).
revoke execute on function public.assign_tables_to_reservation(uuid, uuid[], uuid, text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.create_or_get_dm(uuid, uuid) from public, anon;
revoke execute on function public.merge_floor_tables(uuid, uuid[], integer) from public, anon;
revoke execute on function public.register_push_token(uuid, text, text) from public, anon;
revoke execute on function public.split_floor_tables(uuid, uuid) from public, anon;
revoke execute on function public.update_floor_table_status(uuid, uuid, text) from public, anon;

grant execute on function public.assign_tables_to_reservation(uuid, uuid[], uuid, text, timestamptz, timestamptz) to authenticated;
grant execute on function public.create_or_get_dm(uuid, uuid) to authenticated;
grant execute on function public.merge_floor_tables(uuid, uuid[], integer) to authenticated;
grant execute on function public.register_push_token(uuid, text, text) to authenticated;
grant execute on function public.split_floor_tables(uuid, uuid) to authenticated;
grant execute on function public.update_floor_table_status(uuid, uuid, text) to authenticated;
