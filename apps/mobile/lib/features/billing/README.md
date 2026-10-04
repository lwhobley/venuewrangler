# features/billing

App subscription status (no Stripe secret material ever reaches this app), backed by
`supabase/migrations/20261002130000_subscriptions_schema.sql` and
`supabase/functions/stripe-create-checkout`, `stripe-create-portal`, `stripe-webhook`. Stripe
is used only for this platform app-subscription — there is no Stripe Connect / connected-account
flow anywhere in this app. BEO deposits are not collected through Stripe (see
`features/crm`'s README for why that feature was removed rather than left half-functional).

- `domain/subscription.dart` — `Subscription`.
- `data/billing_repository.dart` — `BillingRepository` interface + Supabase implementation:
  `fetchSubscription` reads `subscriptions` directly (RLS limits this to org owners/admins —
  a non-admin simply sees `null`, not an error); `createCheckoutUrl`/`createPortalUrl` invoke
  the two Edge Functions and return a hosted Stripe URL.
- `application/billing_providers.dart` — repository + subscription-for-org provider.
- `presentation/billing_screen.dart` — routed at `/billing`: shows subscription status
  without a purchase link. App subscriptions are sold directly to organizations outside
  the mobile app. The existing Checkout and Portal Edge Functions remain available for
  an appropriate business sales channel; the app does not call them.

**Stripe account note:** this project's Stripe account is livemode-only (no test/sandbox
account) and is shared with other, unrelated projects. `STRIPE_SECRET_KEY`/
`STRIPE_WEBHOOK_SECRET` must be set as real live secrets via the Supabase dashboard's Edge
Function secrets page (same as Groq's — see supabase/.env.example), and the webhook endpoint
itself (`.../functions/v1/stripe-webhook`, listening for `checkout.session.completed`,
`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`) must be created in the Stripe dashboard by hand — this was
deliberately not automated to avoid making a live, shared-account configuration change
without explicit confirmation.
