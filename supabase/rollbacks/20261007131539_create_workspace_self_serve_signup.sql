-- Manual reverse migration. Only removes the RPC; workspaces it already created are
-- ordinary organizations/venues/memberships rows and are deliberately left in place.
begin;
drop function if exists public.create_workspace(text, text, text);
commit;
