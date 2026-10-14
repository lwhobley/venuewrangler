import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import { expect, it } from 'vitest';

it('overlapping expired checkout retries share the replacement session', async () => {
  let handler!: (req: Request) => Promise<Response>;
  let key = 'expired-key';
  let sessionId: string | null = 'cs_expired';
  let retrieves = 0;
  let release!: () => void;
  const bothRetrieved = new Promise<void>(resolve => { release = resolve; });
  const createdKeys = new Set<string>();
  const query = (result: unknown) => ({
    select() { return this; }, eq() { return this; }, is() { return this; }, in() { return this; },
    async maybeSingle() { return { data: result, error: null }; },
  });
  const client = {
    auth: { async getUser() { return { data: { user: { id: 'caller' } }, error: null }; } },
    from(table: string) {
      return query(table === 'memberships' ? { role: 'organization_owner' } :
        { stripe_customer_id: 'cus_mock', stripe_subscription_id: null, status: 'none' });
    },
    async rpc(name: string, args: Record<string, unknown>) {
      if (name === 'claim_subscription_checkout_attempt') {
        // Model the database compare-and-swap, not a timing window.
        if (args.p_force_new && args.p_expected_key === key) {
          key = 'replacement-key';
          sessionId = null;
        }
        return { data: [{ idempotency_key: key, stripe_session_id: sessionId }], error: null };
      }
      if (args.p_idempotency_key !== key) return { data: false, error: null };
      sessionId = String(args.p_stripe_session_id);
      return { data: true, error: null };
    },
  };
  const stripe = { checkout: { sessions: {
    async retrieve() {
      if (++retrieves === 2) release();
      await bothRetrieved;
      return { status: 'expired' };
    },
    async create(_body: unknown, options: { idempotencyKey: string }) {
      createdKeys.add(options.idempotencyKey);
      return { id: `cs_${options.idempotencyKey}`, url: `https://example.test/${options.idempotencyKey}`, expires_at: 2_000_000_000 };
    },
  } } };
  const source = ts.transpileModule(readFileSync('supabase/functions/stripe-create-checkout/index.ts', 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  runInNewContext(source, {
    exports: {}, console, Request, Response, AbortSignal,
    Deno: { env: { get: () => 'configured-placeholder' }, serve: (fn: typeof handler) => { handler = fn; } },
    require(name: string) {
      if (name.includes('supabase-clients')) return { createServiceClient: () => client, createUserClient: () => client };
      if (name.includes('/stripe')) return { createStripeClient: () => stripe };
      if (name.includes('cors')) return { corsHeaders: {}, handleCorsPreflight: () => null };
      return { initObservability() {}, captureException() {}, async flushObservability() {} };
    },
  });
  const responses = await Promise.all([1, 2].map(() => handler(new Request('https://example.test/checkout', {
    method: 'POST', headers: { Authorization: 'Bearer mock', 'Content-Type': 'application/json' },
    body: JSON.stringify({ organization_id: 'org' }),
  }))));
  expect(responses.map(response => response.status)).toEqual([200, 200]);
  expect(createdKeys.size).toBe(1);
  expect(await responses[0].json()).toEqual(await responses[1].json());
});
