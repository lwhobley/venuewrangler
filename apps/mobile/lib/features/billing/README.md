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

**Event deposits:** Billing also lets organization owners/admins set up a separate Stripe
connected account. `stripe-connect-account` creates or resumes Stripe-hosted onboarding and
reports live card-payment and payout capability status. BEO Checkout uses a direct charge on
that account, with the account ID recorded beside the Checkout Session; it requires both
capabilities active. Subscription Checkout and the Customer Portal continue using the
platform account.

Deploy `20261003005000_payment_and_notification_hardening.sql` before the changed functions.
Set `STRIPE_CONNECT_RETURN_URL` and `STRIPE_CONNECT_REFRESH_URL` to working HTTPS billing
return pages, and configure a connected-account webhook destination for
`checkout.session.completed`, `checkout.session.async_payment_succeeded`, and
`checkout.session.async_payment_failed` at
`.../functions/v1/stripe-webhook`. Store its signing secret as
`STRIPE_CONNECT_WEBHOOK_SECRET` separately from the platform webhook secret. The return
page tells users to reopen Billing and refresh account status; an expired link can be
resumed there. Do not enable deposit collection until the migration, function, webhook,
and onboarding URLs are deployed and verified together. Existing platform-created BEO
Checkout links should be expired or reconciled during rollout; the changed Checkout function
expires each prior open link when that BEO is requested again.

**Stripe account note:** this project's Stripe account is livemode-only (no test/sandbox
account) and is shared with other, unrelated projects. `STRIPE_SECRET_KEY`/
`STRIPE_WEBHOOK_SECRET` must be set as real live secrets via the Supabase dashboard's Edge
Function secrets page (same as Groq's — see supabase/.env.example), and the webhook endpoint
itself (`.../functions/v1/stripe-webhook`, listening for `checkout.session.completed`,
`customer.subscription.created`, `customer.subscription.updated`,
`customer.subscription.deleted`) must be created in the Stripe dashboard by hand — this was
deliberately not automated to avoid making a live, shared-account configuration change
without explicit confirmation.
