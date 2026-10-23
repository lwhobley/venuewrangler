import { handleInvite, type InviteDeps } from "./index.ts";

function fixture(
  options: {
    forbidden?: boolean;
    emailFailure?: boolean;
    missingConfig?: boolean;
    limited?: boolean;
  } = {},
) {
  const sent: Record<string, unknown>[] = [];
  let prepared = 0;
  const deps: InviteDeps = {
    userClient: () =>
      ({
        auth: {
          getUser: () =>
            Promise.resolve({ data: { user: { id: "caller" } }, error: null }),
        },
        rpc: () => {
          prepared++;
          return Promise.resolve(
            options.forbidden ? { data: null, error: { code: "42501" } } : {
              data: { id: "invite-id", email: "stored@example.test" },
              error: null,
            },
          );
        },
      }) as unknown as ReturnType<InviteDeps["userClient"]>,
    serviceClient: () => ({}) as ReturnType<InviteDeps["serviceClient"]>,
    rateLimit: () =>
      Promise.resolve(
        options.limited ? new Response(null, { status: 429 }) : null,
      ),
    env: (name) =>
      options.missingConfig ? undefined : ({
        RESEND_API_KEY: "fixture",
        EMAIL_FROM: "team@example.test",
        INVITE_APP_URL: "https://app.example.test/#/sign-up?join=1",
      } as Record<string, string>)[name],
    send: (_url, init) => {
      sent.push(JSON.parse(String(init?.body)));
      return Promise.resolve(
        new Response(null, { status: options.emailFailure ? 502 : 200 }),
      );
    },
  };
  const request = (body: Record<string, unknown> = {}) =>
    new Request("https://functions.test/invite-member", {
      method: "POST",
      headers: {
        Authorization: "Bearer fixture",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        venue_id: "e3000000-0000-0000-0000-000000000001",
        email: "input@example.test",
        role: "staff",
        ...body,
      }),
    });
  return { deps, sent, request, prepared: () => prepared };
}
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

Deno.test("invite refuses unauthenticated requests before preparing or sending", async () => {
  const f = fixture();
  equal(
    (await handleInvite(
      new Request("https://functions.test", { method: "POST" }),
      f.deps,
    )).status,
    401,
  );
  equal(f.prepared(), 0);
  equal(f.sent.length, 0);
});
Deno.test("invite cannot bypass the venue authorization RPC", async () => {
  const f = fixture({ forbidden: true });
  equal((await handleInvite(f.request(), f.deps)).status, 403);
  equal(f.sent.length, 0);
});
Deno.test("invite rejects elevated roles and malformed recipients", async () => {
  const f = fixture();
  equal(
    (await handleInvite(f.request({ role: "organization_owner" }), f.deps))
      .status,
    400,
  );
  equal(
    (await handleInvite(f.request({ email: "broken" }), f.deps)).status,
    400,
  );
  equal(f.prepared(), 0);
  equal(f.sent.length, 0);
});
Deno.test("invite limits sends before preparing an invitation", async () => {
  const f = fixture({ limited: true });
  equal((await handleInvite(f.request(), f.deps)).status, 429);
  equal(f.prepared(), 0);
});
Deno.test("invite reports missing configuration and delivery failures", async () => {
  const missing = fixture({ missingConfig: true });
  equal((await handleInvite(missing.request(), missing.deps)).status, 503);
  const failed = fixture({ emailFailure: true });
  equal((await handleInvite(failed.request(), failed.deps)).status, 502);
});
Deno.test("invite sends only to the stored authorized recipient", async () => {
  const f = fixture();
  equal((await handleInvite(f.request(), f.deps)).status, 200);
  equal(f.sent[0].to, ["stored@example.test"]);
});
