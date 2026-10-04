// Accounts v2 is deliberately separate from the platform's v1 subscription
// customer/Checkout integration. Direct charges use the resulting acct_ ID.
const CONNECT_API_VERSION = "2026-09-30.endive";

interface MerchantAccount {
  id: string;
  configuration?: {
    merchant?: {
      capabilities?: {
        card_payments?: { status?: string };
        stripe_balance?: { payouts?: { status?: string } };
      };
    };
  };
}

async function connectRequest<T>(
  method: string,
  path: string,
  body?: Record<string, unknown>,
  idempotencyKey?: string,
): Promise<T> {
  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!secret) throw new Error("stripe_not_configured");
  const response = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${secret}`,
      "Stripe-Version": CONNECT_API_VERSION,
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) {
    const errorBody = await response.json().catch(() => ({}));
    const code = errorBody?.error?.code ?? "request_failed";
    throw new Error(`stripe_connect_${response.status}_${code}`);
  }
  return await response.json() as T;
}

export async function createMerchantAccount(input: {
  organizationId: string;
  name: string;
  email: string;
  country: string;
}): Promise<string> {
  const account = await connectRequest<MerchantAccount>(
    "POST",
    "/v2/core/accounts",
    {
      display_name: input.name,
      contact_email: input.email,
      dashboard: "full",
      identity: { country: input.country },
      configuration: {
        merchant: { capabilities: { card_payments: { requested: true } } },
      },
      defaults: {
        responsibilities: {
          fees_collector: "stripe",
          losses_collector: "stripe",
        },
      },
      metadata: { organization_id: input.organizationId },
    },
    `venue-wrangler-connect-${input.organizationId}`,
  );
  if (!/^acct_[A-Za-z0-9]+$/.test(account.id)) {
    throw new Error("stripe_connect_invalid_account_id");
  }
  return account.id;
}

export async function getMerchantAccount(accountId: string): Promise<{
  ready: boolean;
  payoutsReady: boolean;
}> {
  if (!/^acct_[A-Za-z0-9]+$/.test(accountId)) {
    throw new Error("stripe_connect_invalid_account_id");
  }
  const query = new URLSearchParams();
  query.set("include[0]", "configuration.merchant");
  const account = await connectRequest<MerchantAccount>(
    "GET",
    `/v2/core/accounts/${accountId}?${query.toString()}`,
  );
  return {
    ready:
      account.configuration?.merchant?.capabilities?.card_payments?.status ===
        "active",
    payoutsReady:
      account.configuration?.merchant?.capabilities?.stripe_balance?.payouts
        ?.status === "active",
  };
}

export function merchantOnboardingRedirectsConfigured(): boolean {
  const returnUrl = Deno.env.get("STRIPE_CONNECT_RETURN_URL");
  const refreshUrl = Deno.env.get("STRIPE_CONNECT_REFRESH_URL");
  return !!returnUrl && !!refreshUrl && returnUrl.startsWith("https://") &&
    refreshUrl.startsWith("https://");
}

export async function createMerchantOnboardingLink(
  accountId: string,
): Promise<string> {
  if (!merchantOnboardingRedirectsConfigured()) {
    throw new Error("stripe_connect_redirects_not_configured");
  }
  const returnUrl = Deno.env.get("STRIPE_CONNECT_RETURN_URL")!;
  const refreshUrl = Deno.env.get("STRIPE_CONNECT_REFRESH_URL")!;
  const link = await connectRequest<{ url: string }>(
    "POST",
    "/v2/core/account_links",
    {
      account: accountId,
      use_case: {
        type: "account_onboarding",
        account_onboarding: {
          collection_options: { fields: "eventually_due" },
          return_url: returnUrl,
          refresh_url: refreshUrl,
        },
      },
    },
  );
  if (!link.url?.startsWith("https://")) {
    throw new Error("stripe_connect_invalid_onboarding_url");
  }
  return link.url;
}
