# features/staff_requests

Phase 4: implemented (port of legacy `packages/api/src/modules/staff-requests/`).

- `domain/staff_request.dart` — Hand-written domain model with `StaffRequestKind` and `StaffRequestStatus` enums.
- `data/staff_requests_repository.dart` — `StaffRequestsRepository` interface and `SupabaseStaffRequestsRepository` implementation for creating, listing, cancelling, and reviewing requests.
- `application/staff_requests_providers.dart` — `staffRequestsRepositoryProvider` and `staffRequestsForVenueProvider(venueId)` Riverpod providers.
- `presentation/staff_requests_screen.dart` — Screen listing staff requests for the active venue (pending first) with who asked (schedule roster names) and the shift's day, time and role. Staff file time off / sick leave (first day required), drop one of their upcoming shifts, or pick up an open one; a blank title is generated. Managers approve or deny with optional notes from a dialog that saves in place, and are warned (and must choose "Approve anyway") before approving a pick-up that double-books.
- Entry points: staff reach it from Home ("Request time off or a shift change") and from the Requests icon on both schedule screens; managers also from More. In both shells the route sits in the Schedule branch.

### Authorization & Database Controls
Authorization is enforced entirely at the database layer via RLS and PostgreSQL triggers in `supabase/migrations/20261002200000_staff_requests_schema.sql`:
- **RLS**: Venue members can insert requests and view their own requests. Venue managers and organization admins can view and review all requests in their venue.
- **`prepare_staff_request_insert` trigger**: Derives `organization_id` from `venue_id`, forces `user_id` to `auth.uid()`, forces initial status to `pending`, and validates `requested_shift_id` belongs to the venue.
- **`enforce_staff_request_update` trigger**: Narrows update permissions so that the original requester can only transition a pending request to `cancelled`, and only a manager can transition a pending request to `approved` or `denied`.
- **`apply_approved_staff_request` trigger**: Automatically handles shift assignment side-effects on approval (`drop_shift`/`open_shift` clears `staff_id`; `add_shift` assigns `staff_id`, refusing a double-booking with 23P01 unless approved through `review_staff_request(..., p_allow_overlap => true)`).
- **`zz_validate_staff_request_shift` trigger** (`20261022120003_staff_request_shift_guards.sql`): drop requests must name the requester's own scheduled shift, pick-ups an open one.
- **`review_staff_request` RPC** (security invoker): the app's review path; requesters are notified of the outcome (`notify_staff_request_reviewed`).

### Not Yet Implemented / Gaps
- Time correction punch-history lookup dialog (the legacy API validated specific past punch IDs). In this pass, time correction is handled as a standard request record.
- Offline queuing for staff request creation (presently online-only; can be integrated into `core/offline` in a follow-up pass).
- Email delivery on review (an in-app/push notification is sent; the legacy code also emailed).
- Two-week availability has no screen yet (the `availability` column is unused).
