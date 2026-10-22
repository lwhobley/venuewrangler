# CRM Feature

Port of legacy NestJS `crm` module (`packages/api/src/modules/crm/`) — leads, BEOs (banquet
event orders), contracts, and a pipeline forecast — to Supabase + Flutter.

## Architecture

- **Database** (`supabase/migrations/20261003002000_crm_schema.sql`):
  - `public.crm_leads`: venue-scoped, a 9-value status enum (new/contacted/.../won/lost/...),
    soft-deletable, assignable to a venue member. A trigger logs every status change to
    `crm_activity_log` automatically, so the audit trail can't be skipped by writing around the
    app layer (legacy's activity log is a best-effort app-layer side effect; this is a trigger).
  - `public.crm_notes`: immutable once created (no update/delete policy), same as legacy.
  - `public.crm_beos`: confirming one with an `event_date` transactionally syncs a real
    `public.reservations` row via a `beo_id` FK, and rolls the whole update back if the venue's
    time slot is already held by another confirmed event/BEO — cancelling releases it. This
    replaces legacy's string-tag pseudo-FK (`tags: ['beo:<id>']`) with a real, unique,
    nullable FK, the single highest-value fix flagged in the legacy audit (a tags[] array isn't
    something an RLS policy can cheaply join through). **No deposit tracking**: Stripe is used
    only for the platform app-subscription (see `features/billing`), never for BEO deposits —
    there is no Stripe Connect / connected-account flow in this app, so the deposit due/paid/
    waived columns and the `waive_beo_deposit` RPC that used to live here were removed rather
    than left half-functional with no way to ever collect one.
  - `public.crm_contracts`: the one real state-machine guard legacy has — once
    `status = 'fully_signed'`, content fields are frozen and the only legal next status is
    `cancelled` or `disputed`. No other lead/BEO/contract status transition is restricted,
    matching legacy exactly (don't assume a stricter machine than the one legacy actually has).
  - `public.crm_activity_log`: written only by triggers/RPCs, never directly by a client insert.
  - `public.email_templates`: CRUD, `{{var}}` substitution done server-side via
    `render_email_template` (RPC), matching legacy's `CrmTemplateService` variable set exactly.
  - RPCs: `crm_pipeline_forecast`, `crm_source_roi`, `crm_stale_leads` (read-only aggregates,
    legacy's STAGE_PROBABILITY weights copied verbatim), `convert_beo_to_contract` (idempotent —
    a second call on an already-converted BEO returns the existing contract rather than
    duplicating it, matching legacy's explicit double-click fix).
- **RLS**: manager-tier only (`venue_manager`/`organization_owner`/`organization_admin`) on
  every table, matching legacy's `canManageVenue` gate on every CRM endpoint including reads —
  staff/supervisor get nothing, not even a read policy.
- **BEO charges** (`supabase/migrations/20261007160000_crm_beo_charges.sql`): itemized
  amounts for food, beverage, room, service, tax, discount, or other charges. Each row
  must match its BEO's venue through a composite foreign key, and manager-tier RLS
  protects reads and writes. Discounts subtract from the recorded total. The food and
  beverage minimum is shown separately because it is a commitment, not another charge.

- **Cancel / restore and the reservation hold**
  (`supabase/migrations/20261022130000_beo_cancel_restore_and_hold_sync.sql`): cancelling a
  BEO records `cancelled_at` and `status_before_cancel` (server-maintained). A manager can
  restore it with `restore_crm_beo` until its date passes; a restored confirmed BEO re-confirms
  its same reservation row after re-checking the four-hour window. The hold reservation
  follows its BEO from the reservation book too: a manager cancelling or restoring the booking
  cancels or restores the event; anyone else is refused (`beo_hold_managed_in_crm`), and a live
  hold can't be moved or deleted from the book. `reservation_hold_conflict` errors carry the
  bookings in the way as JSON in DETAIL (`app_hidden.reservation_hold_conflicts`); the app
  names them (`guests_reservations/domain/hold_conflict.dart`) instead of blaming "another
  confirmed event" when dinner reservations block the night.
- **Time zone**: BEO dates are entered and shown on the venue's clock (`venueClockProvider`,
  `domain/beo_time.dart`), never the device's.

## Not built here (documented gap, not silently skipped)

- **Resend email delivery** (BEO emails, template sends): no Resend integration exists anywhere
  in this rebuild yet.
- The legacy public leads webhook does **not** feed this module — it writes to `public.guests`
  (a separate, already-ported concept). Confirmed from reading the legacy code, not assumed.

## Flutter

`presentation/crm_screen.dart` — a 4-tab screen (Leads / BEOs / Contracts / Forecast).
The BEO tab opens `presentation/crm_beo_detail_screen.dart`, which displays the order's
event, menu, instructions, and itemized charges. Managers can add and remove charge
lines there; tax and service amounts must be entered explicitly rather than inferred.
Cancelling a BEO asks first (naming its date, guests and recorded charges) and offers Undo;
a cancelled BEO whose date hasn't passed shows Restore (`presentation/beo_cancellation.dart`).
The New lead / New BEO / Add note forms (`presentation/crm_form_dialogs.dart`) save from
inside the dialog and close only on success, so a blank field or failed save never loses input.
`presentation/crm_lead_detail_screen.dart` — a lead's notes and activity trail, plus inline
status change. Both rely entirely on RLS for authorization, same as every other feature in this
app — no client-side role check duplicates what the database already enforces.
