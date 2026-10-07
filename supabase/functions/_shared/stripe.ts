import Stripe from "stripe";

// Stripe's Node SDK works in Deno via esm.sh given a fetch-based HTTP client (no Node net/tls
// APIs) and `constructEventAsync` instead of the sync `constructEvent`, which needs Node's
// crypto module that Deno's edge runtime doesn't provide.
// Pinned to this account's actual default API version (confirmed via its existing webhook
// endpoints' `api_version` field) rather than whatever stripe-node@23 defaults to, so response
// shapes stay predictable regardless of library/account version drift — this matters
// concretely for subscription items, where current_period_end/start moved off the top-level
// Subscription object in recent API versions (see stripe-webhook/index.ts).
const STRIPE_API_VERSION = "2025-11-17.clover";

export function createStripeClient(): Stripe {
  return new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
    apiVersion: STRIPE_API_VERSION as Stripe.LatestApiVersion,
    httpClient: Stripe.createFetchHttpClient(),
  });
}
