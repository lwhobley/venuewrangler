# Guests & Reservations Feature

Port of legacy NestJS `guests` and `reservations` modules to native Supabase + Flutter.

## Architecture

- **Database**:
  - `public.guests`: venue-scoped guest CRM records, dietary preferences, tags, contact info.
  - `public.guest_household_links`: links guests belonging to the same household/company within the same venue. Cross-venue links are prevented by database trigger.
  - `public.reservations`: venue-scoped bookings, party size, reservation times, statuses (`pending`, `confirmed`, `seated`, `completed`, `cancelled`, `no_show`), deposit tracking (`none`, `required`, `pending`, `paid`, `refunded`).
  - `public.reservation_connections`: external reservation platform credentials & status with SHA-256 hashed webhook secret, strictly hidden from authenticated users via column-level security.
  - `public.webhook_replay_log`: atomic replay protection log for external webhook delivery.
- **Triggers**:
  - `app_hidden.guests_derive_org_and_lock_venue`: guarantees `organization_id` is derived from `venue_id` and locks tenant IDs.
  - `app_hidden.guest_household_links_derive`: validates that linked guests belong to the same venue.
  - `app_hidden.reservations_derive_org_and_lock_venue`: derives `organization_id` from `venue_id`.
- **Security & RLS**:
  - Full tenant isolation via `FORCE ROW LEVEL SECURITY`.
  - Venue members can view guests and reservations.
  - Staff and managers can insert/update reservations.
  - Manager-only deletion policy.
  - Column-level grant on `reservation_connections` withholding secret hashes from client access.
- **Flutter UI**:
  - `ReservationsScreen`: Filterable reservation feed by status (`All`, `Confirmed`, `Seated`, `Completed`, `Cancelled`), party size badges, quick status transition popups, and new booking dialog.
