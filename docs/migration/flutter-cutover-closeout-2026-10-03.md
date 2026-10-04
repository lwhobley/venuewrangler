# Flutter cutover closeout — 2026-10-03

Target: Supabase project `puttwjwmwrzmhpsjykuj`. Flutter uses Supabase for application
data and Edge Functions, with Firebase only for Android push notifications.

## Verified current state

- Supabase dashboard identifies `puttwjwmwrzmhpsjykuj` as the production project.
- Its latest recorded migration is `attestation_challenges_schema`. The committed
  `20261003005000_payment_and_notification_hardening.sql` is not recorded as applied.
- The project is on the Free plan. Its Backups page says project backups are not
  included, and the overview shows no last backup. Do not apply the payment
  migration or move legacy data until a restorable backup has been created and
  its restore path is established.
- The live Edge Function secrets list includes the platform Stripe credentials,
  Firebase service account, APNs/App Attest settings, Sentry DSN, and Resend key.
  It does not show `STRIPE_CONNECT_WEBHOOK_SECRET`,
  `STRIPE_CONNECT_RETURN_URL`, or `STRIPE_CONNECT_REFRESH_URL`. Secret presence
  alone does not demonstrate a successful transaction or event delivery.
- A read-only count query returned zero rows in `auth.users`, `organizations`,
  `venues`, `memberships`, `subscriptions`, `crm_beos`, and `documents` on the
  Flutter project. This is an empty target, not a completed migration of
  legacy venue data. The legacy source needs a separate inventory and mapping.
- The existing Stripe `venueflutter` webhook destination is active for five
  platform-account events, including `checkout.session.completed` and
  `checkout.session.async_payment_succeeded`. It has no deliveries in the
  dashboard's current-week view. No destination for connected-account events
  was visible in the destination list.
- The local, ignored `supabase/.temp/project-ref` has been corrected to the target
  project. It is not a substitute for an authenticated `supabase link` check.

## Ordered release work

1. Create a restorable backup of the target database, confirm how it would be
   restored, and record a protected backup reference without copying data or
   credentials into this repository.
2. Compare all local migration effects with the live schema, including the
   manually applied storage worker. Apply
   `20261003005000_payment_and_notification_hardening.sql` to the target project
   and confirm its recorded version and resulting grants. Do not run a blind
   `db push` against the old ignored project reference or infer migration state
   from filenames alone.
3. Deploy the matching `crm-create-deposit-checkout`, `stripe-connect-account`,
   `stripe-webhook`, `notifications-send`, and `toast-pos` functions from the
   committed revision. Confirm no other CI or dashboard deployment overwrites
   them. Keep deposit collection disabled until the migration and connected
   account webhook are both in place.
4. Configure the Stripe connected-account webhook and its own signing secret,
   plus verified HTTPS return and refresh URLs. Reconcile or expire older BEO
   Checkout links. Complete a controlled real transaction and verify checkout,
   webhook, BEO state, refund/cancellation, and payout using the actual account.
5. Verify live Resend delivery, Sentry event delivery, and any payroll OAuth
   provider enabled for launch. Keep unverified integrations disabled or marked
   unavailable.
6. For Toast inbound check ingestion, provision a unique random per-venue
   webhook secret of at least 32 characters. Store only its lowercase SHA-256
   hex digest in the active Toast `pos_connections.webhook_secret_hash` row.
   The calling gateway must send `X-Venue-Webhook-Secret`. Direct Toast delivery
   requires verification of Toast's actual signing scheme before it is enabled.
7. Connect a real, network-reachable `clamd` instance and set `CLAMAV_HOST`.
   `documents-upload` already fails closed (503) without one, so no action is
   needed to avoid unscanned uploads — this item is just "make uploads work."
8. Map and rehearse legacy user, organization, venue, membership, subscription,
   schedule, inventory, time, CRM, media, and in-flight payment migration.
   Reconcile record counts and business balances; preserve a rollback path.
9. With installed test apps, exercise App Attest, APNs, FCM, App Links, notification
   navigation, offline reconnect, and tenant isolation on physical devices.
10. Run Expo/Cloud Run and Flutter/Supabase in parallel with real venue users.
    Retire the legacy API only after old clients and webhooks have stopped using it
    and the replacement has a proven rollback route.

## Mobile billing policy

The Flutter Billing screen shows app subscription status without an in-app
Stripe Checkout or Portal link. Direct organization sales can continue through
an appropriate business channel. Event deposits use Stripe Connect for a
real-world venue service and remain a separate payment flow. Before store
submission, review the actual storefronts and distribution model against the
then-current Apple and Google payments rules.

## Evidence limits

This document records dashboard observations and repository changes, not live
payment, device, backup-restore, or data-migration success. None of the legacy
Expo, NestJS, Prisma, or Cloud Run components has been decommissioned.
