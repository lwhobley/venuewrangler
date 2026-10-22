-- Launch review D2: a schedule board left open must not undo a teammate's change.
--
-- Every shift carries a version that the database bumps on each update. The app sends only the
-- fields a manager edited and filters its update on the version it last read, so an edit made
-- from a stale board matches no row instead of writing old values back over a newer change
-- (for example a swap accepted in the meantime). The app then reloads and says so.
--
-- shifts and shift_swaps also join the realtime publication so open boards refresh when a
-- teammate changes the schedule. Realtime applies the same RLS as a select.

alter table public.shifts add column version integer not null default 1;

create or replace function app_hidden.sync_shift_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  new.updated_at := now();
  -- Never client-supplied: a write can only move the version forward by one.
  new.version := old.version + 1;
  return new;
end;
$$;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public'
        and tablename = 'shifts') then
      alter publication supabase_realtime add table public.shifts;
    end if;
    if not exists (select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public'
        and tablename = 'shift_swaps') then
      alter publication supabase_realtime add table public.shift_swaps;
    end if;
  end if;
end;
$$;
