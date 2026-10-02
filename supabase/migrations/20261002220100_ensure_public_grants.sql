-- Ensure tables in public schema have standard Supabase grants for authenticated and anon roles,
-- and set default privileges for future tables created by the postgres role.

grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;
grant usage on all sequences in schema public to authenticated;

alter default privileges for role postgres in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema public grant select on tables to anon;
alter default privileges for role postgres in schema public grant usage on sequences to authenticated;

-- Maintain column-level restriction on sensitive columns
revoke all on public.payroll_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, status, external_account_id,
  token_expires_at, last_error, connected_by, created_at, updated_at
) on public.payroll_connections to authenticated;
