# features/venues

Scaffolded in Phase 1; not implemented yet. Implementation lands in Phase 2/3 per
`docs/migration/flutter-supabase-rebuild-plan.md`.

Venue list/detail/settings UI. Reads venues/memberships via RLS (supabase/migrations/20261002000000_foundation_schema.sql); venue create/update goes through RLS-governed direct client writes restricted to organization_owner/organization_admin.
