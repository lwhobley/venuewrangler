# features/integrations

Scaffolded in Phase 1; not implemented yet. Implementation lands in Phase 2/3 per
`docs/migration/flutter-supabase-rebuild-plan.md`.

Square/QuickBooks/Gusto connection, sync status, and error-state screens. Never renders a provider secret or raw OAuth token; all of that lives only in integration_connections, readable only by service-role Edge Functions.
