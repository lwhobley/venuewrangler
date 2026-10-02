# features/dashboard

The authenticated app's landing screen (`/`), aggregating tasks/events/inventory/schedule
counts for the active venue — no new migration; it composes the providers each of those
features already exposes (`tasksForVenueProvider`, `shiftsForVenueProvider`,
`eventsForVenueProvider`, `inventoryForVenueProvider`).

- `presentation/dashboard_screen.dart` — a 2x2 grid of stat tiles (open tasks, today's
  shifts, upcoming events, inventory item count), each deep-linking into its own feature
  screen, plus a "More" list for the screens that don't fit a summary tile (checklists,
  incidents, Ask Wrangler, staff, billing, integrations, settings). Replaces the earlier
  `PlaceholderHomeScreen`, which is now deleted.

**Not implemented yet:** any AI-generated "daily brief" — the plan's "AI insights" aggregation
is advisory-only per `features/ai/README.md`'s manual-fallback requirement, and would layer on
top of this screen (e.g. a Wrangler-generated summary of the counts already shown) rather than
replace it; a reasonable follow-up once the `wrangler_ask` prompt has access to real venue
context instead of just what the user types.
