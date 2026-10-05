-- Hardening follow-up, caught by Supabase's own performance linter after applying migrations
-- to a real project (not visible locally — the CI stub's plain Postgres has no such linter).
-- Two findings, both fixed here as new policies replacing the old ones, not edits to the
-- original migrations:
--
-- 1. auth_rls_initplan: a bare `auth.uid()` in a policy's USING/WITH CHECK is re-evaluated
--    once per candidate row during a scan; wrapping it as `(select auth.uid())` lets Postgres
--    evaluate it once per query instead (it becomes an InitPlan). Affects
--    profiles_select_self, profiles_update_self, memberships_select_self,
--    operational_tasks_update_managers_or_assignee,
--    incidents_update_managers_or_reporter_while_open. Trigger-function bodies (e.g.
--    `new.created_by := auth.uid()`) are unaffected by this and intentionally left as-is —
--    they already run once per written row, not once per row scanned.
-- 2. multiple_permissive_policies: `memberships` and `profiles` each had two separate
--    permissive SELECT policies for `authenticated` (self-row vs. broader-scope), which
--    Postgres must evaluate both of and OR together on every query. Merged each pair into a
--    single policy with an explicit OR, same resulting visibility, one policy evaluation
--    instead of two.

drop policy profiles_select_self on public.profiles;
drop policy profiles_select_shared_scope on public.profiles;

create policy profiles_select_self_or_shared_scope on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or app_hidden.shares_scope_with(id)
  );

drop policy profiles_update_self on public.profiles;

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

drop policy memberships_select_self on public.memberships;
drop policy memberships_select_org_admins on public.memberships;

create policy memberships_select_self_or_org_admins on public.memberships
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or app_hidden.has_org_role(organization_id, array['organization_owner', 'organization_admin']::public.app_role[])
  );

drop policy operational_tasks_update_managers_or_assignee on public.operational_tasks;

create policy operational_tasks_update_managers_or_assignee on public.operational_tasks
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or assigned_to = (select auth.uid())
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or assigned_to = (select auth.uid())
  );

drop policy incidents_update_managers_or_reporter_while_open on public.incidents;

create policy incidents_update_managers_or_reporter_while_open on public.incidents
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or (reported_by = (select auth.uid()) and status = 'open')
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
    or reported_by = (select auth.uid())
  );
