# Venue Wrangler

Venue Wrangler is a native iOS/Android venue ops app built with Flutter and
Supabase (Postgres, Auth, Storage). Firebase is used only for Android push.

## Role model

- Admin/owner/manager: full visibility and edit access for schedule, floor plan, staff, requests, and live operations
- Staff/server: personal time clock punching, own hours, request flows, read-only schedule visibility, and **operating** the floor during service — seating and clearing the waitlist and changing table status. They cannot **design** the floor: plan edits, table merges/splits, and reservation/waitlist table assignments stay manager-only.

The floor split is deliberate: a host seating guests is not a manager. The
matrix is enforced server-side by Supabase RLS policies and
`SECURITY DEFINER` functions (`supabase/migrations`), with pgTAP tests under
`supabase/tests/database` keeping policy and behavior from drifting apart —
the destructive actions available to the lowest-privilege role (removing a
waitlist party, changing table status) are recorded in the audit log.

## What works now

- Supabase Auth bootstrap (org/venue membership, roles)
- Venue assignment
- Precise GPS geofenced clock-in and clock-out, with server-enforced
  timestamp integrity and auditable corrections
- Manager/admin live clock board
- Weekly schedule calendar
- Staff request flows for add/drop shifts, time off, and two-week availability
- Floor plan and table management with drag-and-drop editor for admins/managers
- Staff management screen for admins/managers to add people, assign roles,
  and manage HR profiles/photos for a venue
- Separate, restricted employee app experience (home KPIs, time clock,
  schedule, floor, profile, team chat)
- Billing shell with Stripe-backed venue subscriptions

## Local setup

The Flutter app lives in `apps/mobile` — see
[`apps/mobile/README.md`](apps/mobile/README.md) for environment flavors,
Supabase project configuration, and architecture notes.

For the root tooling (marketing site, CI scripts, shared tests):

1. `npm install`
2. `npm run dev:marketing` to run the marketing site locally, or `npm run build:site` to build it.

## Quality gates

- `npm run typecheck` — strict TypeScript for root scripts/tests, must be clean.
- `npm test` — root Vitest suite (CI workflow checks, marketing build helpers).
- Flutter: `flutter analyze` and `flutter test` from `apps/mobile`.

## Backend

- Supabase Postgres, Auth, and Storage; authorization enforced via RLS
  policies and `SECURITY DEFINER` functions in `supabase/migrations`
- Firebase Cloud Messaging for Android push notifications

## Floor sync

- Seed a sample floor plan from the Floor Editor if you need demo tables
- Admin/manager can save and publish floor changes
- Staff can view the floor but cannot edit it
