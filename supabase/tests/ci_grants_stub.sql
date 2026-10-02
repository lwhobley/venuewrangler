-- CI-only fixture, applied AFTER supabase/migrations/*.sql: grants the broad table-level
-- privileges a real Supabase project gives anon/authenticated by default. Real Supabase
-- relies on RLS (not GRANT) to do row-level filtering, so this makes the CI stub match
-- production behavior for the authorization tests under supabase/tests/database. See
-- ci_auth_stub.sql for why this exists.

grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage on all sequences in schema public to authenticated;
