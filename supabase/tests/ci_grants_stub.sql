-- CI-only fixture, applied AFTER supabase/migrations/*.sql. Real Supabase grants anon and
-- authenticated broad table privileges by default when a table is created, and then relies on
-- RLS (not GRANT) for row-level filtering. The migrations own every narrowing (column-level
-- grants, revokes) on top of that, so this stub does not repeat any of it.
--
-- Simulation: give the default privileges only to public tables that no migration has granted
-- or revoked anything on (relacl IS NULL). Tables a migration has touched keep the exact ACL the
-- migration left, so the authorization tests check the migrations, not a re-narrowed copy.
-- See ci_auth_stub.sql for why this exists.

do $$ declare r record; begin
  for r in
    select c.oid::regclass as tbl
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relacl is null
  loop
    execute format('grant select, insert, update, delete on %s to authenticated', r.tbl);
    execute format('grant select on %s to anon', r.tbl);
  end loop;
end $$;

grant usage on all sequences in schema public to authenticated;
