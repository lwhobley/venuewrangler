# Audit remediation — 2026-10-14

All ten audit findings are implemented and verified locally. Release rollout is authorized; hosted deployment results are recorded separately.

## Release rollout

- Implementation commit `635a88c` pushed to `main`.
- Production project `puttwjwmwrzmhpsjykuj`: all six pending review/audit migrations applied successfully. Verified RPC permissions, POS trigger, studio constraints, zero malformed studio rows, and no enabled legacy push registrations.
- Deployed `stripe-create-checkout` v34, `notifications-send` v37, and `notifications-dispatch` v16, preserving their authentication settings. Live unauthenticated calls return 401.
- GitHub Actions passed: 720 database assertions across 45 files, 321 Flutter tests, backend checks, and CodeQL.
- Initial Cloudflare deployment succeeded, but live verification exposed Pages redirecting `scene.html` to `scene`. The follow-up fixes the narrow framing exception on both URLs and adds a redirect regression test; 16 JavaScript tests and TypeScript checking pass.
- Pushed `ios-v1.12.0-7` at `635a88c`; Codemagic acknowledged the tag push with HTTP 202. Build completion and TestFlight upload are not verified here. The follow-up affects only web hosting headers, not the native app.

| Finding | Implementation |
|---|---|
| AUD-01 | Expired Checkout replacement compares the exact observed attempt key under the existing lock. Concurrent stale callers reuse the replacement. The later ten-second mitigation was discovered during implementation and the audit's original reproduction claim was corrected. |
| AUD-02 | Device-generated 256-bit revocation secrets are retained in secure storage across account changes. Only hashes are stored server-side. Proof permits deferred revocation from a later session; invalid proof cannot take over or revoke another account's token. Verified failures keep their retry marker. Sign-out disposes refresh listeners and cleans up registrations that finish late. Push transport alerts contain generic text and no account identifiers or details; the authenticated inbox retains the real content. |
| AUD-03 | A database trigger enforces final POS states under PostgreSQL's row lock, including concurrent upserts. Closed checks can become voided; stale opens and reversals of a void are ignored. Ownership mutation still raises an authorization error. |
| AUD-04 | Only the 3D scene asset receives a same-origin framing policy and inline-script allowance. Other assets, marketing pages, and the app shell keep their framing protection. |
| AUD-05 | Reservation form values are formatted as venue wall-clock fields, without applying the venue offset twice. |
| AUD-06 | Event entry, date-picker bounds, persistence conversion, and display use the active venue's timezone. |
| AUD-07 | Loading errors block studio editing and offer Retry. Successful loads alone populate and latch the saved state. |
| AUD-08 | Save, generation, and validity messages include object boundaries, rotated object intersections, and table clearance. Oversized new objects are rejected. |
| AUD-09 | New table-layout writes must satisfy database shape and finite-dimension constraints. Existing malformed records remain intact for repair and surface as per-plan errors; healthy plans still load. |
| AUD-10 | BEO links carry the selected venue and plan. The editor opens that plan, refuses a different active venue, and reports a missing target instead of choosing another room silently. |

## Database and rollout

Production preflight also found the three earlier `20261013100000`, `20261013100100`, and `20261013100200` review migrations absent. Apply those first, then the three new migrations in order, then deploy `stripe-create-checkout`, `notifications-send`, and `notifications-dispatch` (the latter two bundle the changed shared push code). Publish the web changes and distribute a new mobile build to deliver client fixes.

- `20261014100000_audit_checkout_and_pos_atomic.sql`
- `20261014101000_audit_device_push_revocation.sql`
- `20261014102000_audit_studio_layout_shape.sql`

The push migration disables existing registrations because they lack installation proof. They register again when the user opens the upgraded app and chooses a venue. Do not roll this out without the accompanying client and generic-alert server changes. Offline logout cannot immediately inform a server; generic transport alerts prevent confidential notification content from leaking during that interval.

The layout constraints use `NOT VALID`: existing malformed data is retained, while new writes are checked. Review and repair any existing rows returned by the following read-only preflight before validating the constraints globally:

```sql
select id, venue_id, floor_plan_id
from public.floor_plan_studio_layouts
where not app_hidden.valid_studio_tables(layout)
   or width_feet in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
   or depth_feet in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8)
   or table_diameter_feet in ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8);
```

No automatic reset or deletion of malformed plans is performed.

## Verification

Final checks: **321 Flutter tests passed**, strict full Flutter analysis passed with no issues, and the formatting gate passed. **15 JavaScript tests passed**, root TypeScript checking passed, changed Edge Functions passed Deno checking/lint, and **7 Edge helper tests passed**. Flutter tests used `--no-test-assets` because the normal asset-build directory is locked locally; native release packaging was not tested.

The regression suite covers checkout handler concurrency, scene-asset security headers, per-plan parse isolation, saved-layout retry, exact BEO target selection, wrong-venue refusal, object/table clearance, rotated footprints, wall-clock conversion, and installation-secret use. SQL regression tests were added under `supabase/tests/database/audit_remediation.test.sql`.

An isolated PostgreSQL 18 instance compiled all three migrations against source-derived fixtures. Native SQL assertions verified checkout key comparison, device proof and ownership transfer, malformed layout rejection, and genuinely concurrent POS transactions. This does not replace the full Supabase/PostgreSQL 15 migration replay and pgTAP suite: Docker was unavailable locally, so that full gate remains for CI.

A real browser loaded the scene iframe with the revised checked-in Worker/header fixture and reported a canvas with no scene-script errors. Actual iPhone/Android behavior and deployed headers remain unverified in this pass.
