import {
  allowedOrigins,
  corsHeaders,
  DEFAULT_ALLOWED_ORIGINS,
  handleCorsPreflight,
  withCors,
  wrapWithCors,
} from "./cors.ts";

function envOf(values: Record<string, string>) {
  return (name: string) => values[name];
}

const PROD = envOf({ ENVIRONMENT: "production" });
const DEV = envOf({ ENVIRONMENT: "development" });

Deno.test("an unset ENVIRONMENT is treated as production: no localhost", () => {
  assertEquals(allowedOrigins(envOf({})).has("http://localhost:3000"), false, "localhost with no env");
});
const INFO = {} as Deno.ServeHandlerInfo;

function request(origin: string | null, method = "POST"): Request {
  const headers = new Headers({ Authorization: "Bearer x" });
  if (origin !== null) headers.set("Origin", origin);
  return new Request("https://ref.supabase.co/functions/v1/fn", { method, headers });
}

function assertEquals(actual: unknown, expected: unknown, label: string) {
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, got ${actual}`);
}

Deno.test("corsHeaders never carries a wildcard Allow-Origin", () => {
  assertEquals("Access-Control-Allow-Origin" in corsHeaders, false, "static header");
});

Deno.test("default allowlist is the production web origins, without localhost in production", () => {
  const prod = allowedOrigins(PROD);
  for (const origin of DEFAULT_ALLOWED_ORIGINS) assertEquals(prod.has(origin), true, origin);
  assertEquals(prod.has("https://venuewrangler.com"), true, "apex");
  assertEquals(prod.has("http://localhost:3000"), false, "localhost in prod");
  assertEquals(allowedOrigins(envOf({ APP_ENV: "prod" })).has("http://localhost:3000"), false, "APP_ENV=prod");
  assertEquals(allowedOrigins(DEV).has("http://localhost:3000"), true, "localhost in dev");
});

Deno.test("CORS_ALLOWED_ORIGINS replaces the defaults and ignores '*'", () => {
  const origins = allowedOrigins(envOf({
    ENVIRONMENT: "production",
    CORS_ALLOWED_ORIGINS: " https://admin.example.com/ , *, ",
  }));
  assertEquals(origins.has("https://admin.example.com"), true, "configured origin");
  assertEquals(origins.has("https://venuewrangler.com"), false, "default replaced");
  assertEquals(origins.has("*"), false, "wildcard");
});

Deno.test("an allowlisted origin is echoed with Vary: Origin", async () => {
  const handler = wrapWithCors(() =>
    new Response("{}", { headers: { ...corsHeaders, "Content-Type": "application/json" } }), PROD);
  const response = await handler(request("https://venuewrangler.com"), INFO);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://venuewrangler.com", "allow-origin");
  assertEquals(response.headers.get("Vary"), "Origin", "vary");
  assertEquals(response.headers.get("Content-Type"), "application/json", "content-type kept");
});

Deno.test("a disallowed origin gets no Allow-Origin, even if a handler set one", async () => {
  const handler = wrapWithCors(() =>
    new Response("{}", { headers: { "Access-Control-Allow-Origin": "*", Vary: "Accept-Encoding" } }), PROD);
  const response = await handler(request("https://evil.example"), INFO);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), null, "allow-origin");
  assertEquals(response.headers.get("Vary"), "Accept-Encoding, Origin", "vary merged");
  assertEquals(response.status, 200, "handler response still returned");
});

Deno.test("localhost is refused in production", async () => {
  const handler = wrapWithCors(() => new Response("ok"), PROD);
  const response = await handler(request("http://localhost:3000"), INFO);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), null, "allow-origin");
});

Deno.test("requests without Origin (native app, pg_net, Stripe) pass through unchanged", async () => {
  let called = false;
  const handler = wrapWithCors(() => {
    called = true;
    return new Response("body", { status: 201 });
  }, PROD);
  const response = await handler(request(null), INFO);
  assertEquals(called, true, "handler called");
  assertEquals(response.status, 201, "status");
  assertEquals(await response.text(), "body", "body");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), null, "allow-origin");
});

Deno.test("preflight from an allowed origin answers 204 with the allow headers", async () => {
  let called = false;
  const handler = wrapWithCors(() => {
    called = true;
    return new Response("no");
  }, PROD);
  const response = await handler(request("https://www.venuewrangler.com", "OPTIONS"), INFO);
  assertEquals(called, false, "handler not called for preflight");
  assertEquals(response.status, 204, "status");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://www.venuewrangler.com", "allow-origin");
  assertEquals(response.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS", "methods");
  assertEquals(response.headers.get("Vary"), "Origin", "vary");
});

Deno.test("preflight from a disallowed origin gets no Allow-Origin", () => {
  const response = handleCorsPreflight(request("https://evil.example", "OPTIONS"), PROD)!;
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), null, "allow-origin");
  assertEquals(handleCorsPreflight(request("https://evil.example"), PROD), null, "non-OPTIONS");
});

Deno.test("immutable response headers are copied into a new Response", async () => {
  const redirect = Response.redirect("venuewrangler://integrations/connected", 302);
  const response = withCors(request("https://venuewrangler.com"), redirect, PROD);
  assertEquals(response.status, 302, "status");
  assertEquals(response.headers.get("Location"), "venuewrangler://integrations/connected", "location");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "https://venuewrangler.com", "allow-origin");
  await response.body?.cancel();
});
