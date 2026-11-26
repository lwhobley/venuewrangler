import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import { expect, it } from 'vitest';

// The function rejects a non-UUID organization_id with 400, so the fixture uses a real one.
const ORG_ID = '10000000-0000-4000-8000-000000000001';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    async rpc(name: string, args: Record<string, unknown> = {}) {
      // MFA step-up gate (_shared/mfa.ts): the caller has satisfied it.
      if (name === 'caller_mfa_satisfied') return { data: true, error: null };
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
      if (name.includes('rate-limit')) return { async enforceRateLimit() { return null; } };
      if (name.includes('cors')) {
        return {
          corsHeaders: {},
          handleCorsPreflight: () => null,
          serveWithCors: (fn: typeof handler) => { handler = fn; },
        };
      }
      if (name.includes('/mfa')) {
        // Mirrors requireCallerMfa: asks the caller's client, blocks unless it answers true.
        return {
          async requireCallerMfa(userClient: typeof client) {
            const { data } = await userClient.rpc('caller_mfa_satisfied');
            return data === true ? null : new Response(JSON.stringify({ error: 'mfa_required' }), { status: 403 });
          },
        };
      }
      if (name.includes('venue-auth')) {
        return { isUuid: (value: unknown) => typeof value === 'string' && UUID.test(value) };
      }
      return { initObservability() {}, captureException() {}, async flushObservability() {} };
    },
  });
  const responses = await Promise.all([1, 2].map(() => handler(new Request('https://example.test/checkout', {
    method: 'POST', headers: { Authorization: 'Bearer mock', 'Content-Type': 'application/json' },
    body: JSON.stringify({ organization_id: ORG_ID }),
  }))));
  expect(responses.map(response => response.status)).toEqual([200, 200]);
  expect(createdKeys.size).toBe(1);
  expect(await responses[0].json()).toEqual(await responses[1].json());
});
