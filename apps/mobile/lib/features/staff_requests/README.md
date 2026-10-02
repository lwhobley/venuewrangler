# features/staff_requests

Phase 4: implemented (port of legacy `packages/api/src/modules/staff-requests/`).

- `domain/staff_request.dart` — Hand-written domain model with `StaffRequestKind` and `StaffRequestStatus` enums.
- `data/staff_requests_repository.dart` — `StaffRequestsRepository` interface and `SupabaseStaffRequestsRepository` implementation for creating, listing, cancelling, and reviewing requests.
- `application/staff_requests_providers.dart` — `staffRequestsRepositoryProvider` and `staffRequestsForVenueProvider(venueId)` Riverpod providers.
- `presentation/staff_requests_screen.dart` — Screen listing staff requests for the active venue, displaying kind and status chips, allowing staff to submit requests or cancel their own pending requests, and allowing managers to approve or deny requests with optional review notes.

### Authorization & Database Controls
Authorization is enforced entirely at the database layer via RLS and PostgreSQL triggers in `supabase/migrations/20261002200000_staff_requests_schema.sql`:
- **RLS**: Venue members can insert requests and view their own requests. Venue managers and organization admins can view and review all requests in their venue.
- **`prepare_staff_request_insert` trigger**: Derives `organization_id` from `venue_id`, forces `user_id` to `auth.uid()`, forces initial status to `pending`, and validates `requested_shift_id` belongs to the venue.
- **`enforce_staff_request_update` trigger**: Narrows update permissions so that the original requester can only transition a pending request to `cancelled`, and only a manager can transition a pending request to `approved` or `denied`.
- **`apply_approved_staff_request` trigger**: Automatically handles shift assignment side-effects on approval (`drop_shift`/`open_shift` clears `staff_id`; `add_shift` assigns `staff_id`).

### Not Yet Implemented / Gaps
- Time correction punch-history lookup dialog (the legacy API validated specific past punch IDs). In this pass, time correction is handled as a standard request record.
- Offline queuing for staff request creation (presently online-only; can be integrated into `core/offline` in a follow-up pass).
- Push notification / email delivery on review (the legacy code sent email templates; waiting on the notification system migration).
