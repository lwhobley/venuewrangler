# features/time_clock

Phase 4: implemented (port of legacy `packages/api/src/modules/time-clock/`).

Provides geofenced time attendance, break tracking, and anti-replay GPS fix verification for staff and managers:

- `domain/time_entry.dart` — Hand-written domain models for `TimeEntry` and `TimeBreak` (paid/unpaid intervals, elapsed calculation, active break detection).
- `domain/geofence_helper.dart` — Client-side Haversine distance calculator matching PostgreSQL `app_hidden.haversine_distance_m`.
- `data/time_clock_repository.dart` — `TimeClockRepository` interface and `SupabaseTimeClockRepository` implementation supporting `getActiveEntry`, `getMyEntries`, `getVenueEntries` (Clock Board), `clockIn`, `clockOut`, `startBreak`, and `endBreak`.
- `application/time_clock_providers.dart` — `timeClockRepositoryProvider`, `activeTimeEntryProvider(venueId)`, `myTimeEntriesProvider(venueId)`, and `venueClockBoardProvider(venueId)` Riverpod providers.
- `presentation/time_clock_screen.dart` — Full time clock UI with live clock timer, punch status banner, break management (paid/unpaid), punch history, and venue-wide active Clock Board.

### Authorization & Database Controls
Authorization is enforced entirely at the database layer via RLS and PostgreSQL triggers in `supabase/migrations/20261002220000_time_clock_schema.sql`:
- **RLS**: Venue members can insert punches and view their own entries. Venue managers, organization owners, and organization admins can view and review all entries across the venue.
- **Geofencing**: Haversine distance (`app_hidden.haversine_distance_m`) runs inside the `prepare_time_entry_insert` and `enforce_time_entry_update` triggers. Punches outside `venue.geofence_radius_m` or reporting accuracy > 50m are rejected.
- **Anti-Replay GPS Detection**: Punches with identical coordinates to fixes from earlier calendar days are evaluated against `GNSS_ACCURACY_THRESHOLD_M` (10m). Exact satellite-grade repeats are rejected; coarse Wi-Fi/cell repeats are permitted but tagged with `location_anomaly = 'repeated_fix'`.
- **One Open Punch Invariant**: Partial unique index on `(user_id) WHERE (is_open = true)` prevents concurrent double-clock-ins.
- **Mock GPS Rejection**: Checked via `clock_in_mocked = false` and `clock_out_mocked = false`.

### Not Yet Implemented / Gaps
- Automated background late clock-in alerts (`ClockAlertDeliveryService` in legacy): depends on the notifications module port.
- Hardware device attestation enforcement: App Attest / Play Integrity verification is integrated at the attestation layer; native mobile platform channel binding for hardware signing keys will be wired during native platform runner initialization.
