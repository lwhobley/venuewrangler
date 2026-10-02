# features/billing

Stripe Checkout/Customer Portal entry points (hosted URLs only — no Stripe secret material
ever reaches this app), backed by `supabase/migrations/20261002130000_subscriptions_schema.sql`
and `supabase/functions/stripe-create-checkout`, `stripe-create-portal`, `stripe-webhook`.

- `domain/subscription.dart` — `Subscription`.
- `data/billing_repository.dart` — `BillingRepository` interface + Supabase implementation:
  `fetchSubscription` reads `subscriptions` directly (RLS limits this to org owners/admins —
  a non-admin simply sees `null`, not an error); `createCheckoutUrl`/`createPortalUrl` invoke
  the two Edge Functions and return a hosted Stripe URL.
- `application/billing_providers.dart` — repository + subscription-for-org provider.
- `presentation/billing_screen.dart` — routed at `/billing`: shows subscription status, a
  "Subscribe" button (opens Checkout via `url_launcher` in an external browser) when not
  entitled, and a "Manage billing" button (opens the Customer Portal) when entitled. A
  non-admin can still tap "Subscribe" since the client doesn't duplicate the role check — the
  Edge Function rejects it and the screen shows that error as a snackbar, same pattern as
  every other Phase 2/3 write path in this app.

**Stripe account note:** this project's Stripe account is livemode-only (no test/sandbox
account) and is shared with other, unrelated projects. `STRIPE_SECRET_KEY`/
`STRIPE_WEBHOOK_SECRET` must be set as real live secrets via the Supabase dashboard's Edge
Function secrets page (same as Groq's — see supabase/.env.example), and the webhook endpoint
itself (`.../functions/v1/stripe-webhook`, listening for `checkout.session.completed`,
`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`) must be created in the Stripe dashboard by hand — this was
deliberately not automated to avoid making a live, shared-account configuration change
without explicit confirmation.
