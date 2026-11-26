// CORS for Edge Functions (audit F07).
//
// Most callers are not browsers: the native Flutter app, pg_net workers, Stripe and POS
// gateways send no `Origin` header and are unaffected by anything here. Browsers (the Flutter
// web build served under https://venuewrangler.com/app/) send `Origin` and a preflight for our
// POST + Authorization + Content-Type requests. Instead of `Access-Control-Allow-Origin: *`,
// the request's Origin is echoed back only when it is on the allowlist, with `Vary: Origin`.
//
// Allowlist: CORS_ALLOWED_ORIGINS (comma-separated exact origins, e.g.
// "https://venuewrangler.com,https://www.venuewrangler.com") replaces the defaults when set.
// Defaults (DEFAULT_ALLOWED_ORIGINS), taken from the repo's production web/marketing hosts:
//  - https://venuewrangler.com      marketing site + /app web build (site/robots.txt,
//                                   site/sitemap.xml, deploy-cloudflare-pages.yml)
//  - https://www.venuewrangler.com  www alias (legacy API CORS allowlist, packages/api)
//  - https://venue-wrangler.pages.dev  Cloudflare Pages project domain (`--project-name
//                                   venue-wrangler`; og:image URLs in site/)
// Only when ENVIRONMENT/APP_ENV is explicitly "development"/"dev"/"local" are the local dev
// origins from supabase/config.toml's site_url added: http://localhost:3000 and
// http://127.0.0.1:3000. An unset value counts as production.
//
// Every function serves through serveWithCors(), which applies the per-request origin to every
// response it returns (including the preflight), so handlers keep building responses with the
// static `corsHeaders` (Allow-Headers/Allow-Methods only, never Allow-Origin).

export const DEFAULT_ALLOWED_ORIGINS: readonly string[] = [
  "https://venuewrangler.com",
  "https://www.venuewrangler.com",
  "https://venue-wrangler.pages.dev",
];

export const DEV_ALLOWED_ORIGINS: readonly string[] = [
  "http://localhost:3000",
  "http://127.0.0.1:3000",
];

/** Static, origin-independent CORS headers. Never carries Access-Control-Allow-Origin. */
export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-correlation-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Env = (name: string) => string | undefined;
const denoEnv: Env = (name) => Deno.env.get(name);

// Local origins are opt-in: a hosted project that never set ENVIRONMENT must not trust localhost.
function isLocalDevelopment(env: Env): boolean {
  const appEnv = (env("ENVIRONMENT") ?? env("APP_ENV") ?? "").trim().toLowerCase();
  return appEnv === "development" || appEnv === "dev" || appEnv === "local";
}

/** The effective allowlist (exact, lowercase origins without a trailing slash). */
export function allowedOrigins(env: Env = denoEnv): Set<string> {
  const configured = (env("CORS_ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim().replace(/\/+$/, "").toLowerCase())
    .filter((origin) => origin.length > 0 && origin !== "*");
  const origins = configured.length > 0 ? configured : [...DEFAULT_ALLOWED_ORIGINS];
  if (isLocalDevelopment(env)) origins.push(...DEV_ALLOWED_ORIGINS);
  return new Set(origins);
}

/** The Origin to echo in Access-Control-Allow-Origin, or null when it is absent/not allowed. */
export function allowedOriginFor(req: Request, env: Env = denoEnv): string | null {
  const origin = req.headers.get("Origin");
  if (!origin) return null;
  return allowedOrigins(env).has(origin.toLowerCase()) ? origin : null;
}

/** CORS headers for one request: the static set plus Allow-Origin when allowlisted. */
export function corsHeadersFor(req: Request, env: Env = denoEnv): Record<string, string> {
  const origin = allowedOriginFor(req, env);
  return origin
    ? { ...corsHeaders, "Access-Control-Allow-Origin": origin, Vary: "Origin" }
    : { ...corsHeaders, Vary: "Origin" };
}

/** Preflight answer for OPTIONS requests, else null. Allow-Origin only for allowlisted origins. */
export function handleCorsPreflight(req: Request, env: Env = denoEnv): Response | null {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeadersFor(req, env) });
  }
  return null;
}

function addVaryOrigin(headers: Headers): void {
  const vary = headers.get("Vary");
  if (!vary) {
    headers.set("Vary", "Origin");
  } else if (!vary.split(",").some((v) => v.trim().toLowerCase() === "origin" || v.trim() === "*")) {
    headers.set("Vary", `${vary}, Origin`);
  }
}

function applyOrigin(headers: Headers, origin: string | null): void {
  headers.delete("Access-Control-Allow-Origin");
  if (origin) headers.set("Access-Control-Allow-Origin", origin);
  addVaryOrigin(headers);
}

/**
 * Applies the request's CORS origin decision to a response built anywhere in a handler. Mutates
 * the headers in place when they are mutable; otherwise (Response.redirect(), a proxied fetch()
 * response) copies them into a new Response around the same body.
 */
export function withCors(req: Request, response: Response, env: Env = denoEnv): Response {
  const origin = allowedOriginFor(req, env);
  try {
    applyOrigin(response.headers, origin);
    return response;
  } catch {
    const headers = new Headers(response.headers);
    applyOrigin(headers, origin);
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  }
}

export type Handler = (req: Request, info: Deno.ServeHandlerInfo) => Response | Promise<Response>;

/** Wraps a handler so the preflight and every response get the per-request CORS headers. */
export function wrapWithCors(handler: Handler, env: Env = denoEnv): Handler {
  return async (req, info) => {
    const preflight = handleCorsPreflight(req, env);
    if (preflight) return preflight;
    return withCors(req, await handler(req, info), env);
  };
}

/** Drop-in replacement for Deno.serve(handler) that applies the CORS allowlist. */
export function serveWithCors(handler: Handler): Deno.HttpServer {
  return Deno.serve(wrapWithCors(handler));
}
