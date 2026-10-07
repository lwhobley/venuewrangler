# Flutter UI and employee profiles correction

The active product is `apps/mobile` (Flutter/Riverpod/Supabase). The Expo/NestJS
implementation in `cc0e3b9` was placed in the wrong app and has been withdrawn.
The subsequent Flutter time-integrity and net-worked-hours fixes are preserved.
The earlier repository review remains a historical snapshot, not the current
status of the withdrawn Expo features.

The Flutter shared theme now uses teal headers/actions, white cards, and light
gray backgrounds, with readable semantic statuses and a light default. Existing
dark/system preferences remain available. Reservations, Inventory, and Team
have one clear bottom action; secondary imports remain in the app bar. Kitchen
display and guest-feedback panels are excluded from this UI.

Team members can upload a photo from the camera or library and edit their contact
and emergency details. Managers can open subordinate employee records from Team
and add photos and employment details. Managers cannot change peer managers;
organization owners/admins can manage them. Employees cannot change pay or leave
balances. The same HR/photo controls appear in employee Profile and manager Settings.

HR fields cover legal/preferred name, contact email, phones, address, birth date,
emergency contacts, employee number, title, department, hire date, employment
type/status, hourly pay, certifications, and PTO/sick-hour balances. Records are
scoped to a user and venue; edits retain that scope and refuse a save after a
venue/account change. Empty fields explicitly clear saved values.

Supabase support is in `20261006212133_flutter_staff_hr_and_photos.sql`:

- `employee_hr_profiles`: self/authorized-manager access with protected employment fields.
- `staff_photos`: team-readable identity metadata without exposing HR details.
- Private `profile-photos` bucket: 5 MB JPEG/PNG/WebP capacity and canonical
  organization/venue/user object paths, with server-side upload authorization.
- One stable object per user/venue; replacement overwrites the prior photo.
- Hour-long signed URLs refreshed before expiry and cache revision on replacement.

The migration must be applied before the new data-backed controls can work against
a Supabase environment. No live migration/deployment is implied by this source
change. Local authorization tests are under `supabase/tests/database/` and Flutter
profile tests under `apps/mobile/test/features/workforce/`.
