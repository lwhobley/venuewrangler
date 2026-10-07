// Error tracking for Edge Functions, porting packages/api/src/observability/sentry.ts (a
// 51-line Sentry wrapper — no Prisma models, no endpoints, nothing to migrate as a Postgres
// schema; see docs/migration/phase4-validation-report.md for the research behind that call).
//
// Uses Sentry's Deno SDK (`npm:@sentry/deno`), per Supabase's own documented pattern for this
// exact runtime: https://supabase.com/docs/guides/functions/examples/sentry-monitoring.
// `defaultIntegrations: false` and the per-call `withScope` wrapper below are both from that
// same guidance — the Deno SDK has no `Deno.serve` instrumentation, so without them, state
// (breadcrumbs, tags) can bleed across unrelated requests when the Edge Function's underlying
// worker is reused.
//
// Preserves the two pieces of the legacy wrapper that are real business logic, not boilerplate:
//  - tracesSampleRate 0 (error tracking only, no performance tracing) and no default PII.
//  - the `beforeSend` redaction: media routes carry short-lived HMAC access tokens as query
//    params, and the legacy code deliberately strips those (and a signup-invite code from the
//    path) before an event ever reaches Sentry. Any Edge Function that touches a signed media
//    URL or invite link must route its errors through `captureException` here, not log the raw
//    request URL some other way, or this protection does nothing.
//  - the 4xx/5xx asymmetry: only unexpected (5xx-equivalent) failures should be reported; a
//    normal 4xx (bad input, forbidden, not found) is not a Sentry-worthy event and would just
//    flood the project with noise, per the legacy code's own call-site convention.
//
// deno-lint-ignore-file no-explicit-any
import * as Sentry from "@sentry/deno";

let enabled = false;
let initialized = false;

const MEDIA_TOKEN_QUERY_PARAMS = new Set(["token", "t", "sig", "signature"]);
const INVITE_PATH_PATTERN = /\/invite\/[^/?]+/i;

function redactUrl(rawUrl: string | undefined): string | undefined {
  if (!rawUrl) return rawUrl;
  try {
    const url = new URL(rawUrl);
    // Redact the invite code segment in the path, same as legacy's safeRequestPath().
    url.pathname = url.pathname.replace(INVITE_PATH_PATTERN, "/invite/[redacted]");
    // Strip any query param that could carry a short-lived HMAC media/access token. Unlike
    // legacy (which truncates the whole query string at "?"), this keeps non-sensitive params
    // for debuggability while still never sending a token value to Sentry.
    for (const key of Array.from(url.searchParams.keys())) {
      if (MEDIA_TOKEN_QUERY_PARAMS.has(key.toLowerCase())) {
        url.searchParams.set(key, "[redacted]");
      }
    }
    return url.toString();
  } catch {
    // Not a parseable URL (e.g. a relative path) — fall back to truncating at the first "?",
    // matching legacy's simpler behavior exactly.
    return rawUrl.split("?")[0];
  }
}

/** Initializes Sentry once per worker instance. No-op (and returns false) if SENTRY_DSN is unset. */
export function initObservability(): boolean {
  if (initialized) return enabled;
  initialized = true;

  const dsn = Deno.env.get("SENTRY_DSN");
  if (!dsn) {
    enabled = false;
    return false;
  }

  Sentry.init({
    dsn,
    defaultIntegrations: false,
    tracesSampleRate: 0,
    sendDefaultPii: false,
    beforeSend(event: any) {
      if (event.request?.url) {
        event.request.url = redactUrl(event.request.url);
      }
      if (event.request?.query_string) {
        delete event.request.query_string;
      }
      return event;
    },
  });
  enabled = true;
  return true;
}

/**
 * Reports an unexpected (5xx-equivalent) failure. Never call this for ordinary 4xx responses
 * (bad input, unauthorized, not found) — see the header comment on why.
 */
export function captureException(error: unknown, context?: Record<string, unknown>): void {
  if (!enabled) return;
  Sentry.withScope((scope: any) => {
    if (context) {
      for (const [key, value] of Object.entries(context)) {
        scope.setExtra(key, value);
      }
    }
    Sentry.captureException(error);
  });
}

/** Drains queued events before a short-lived Edge Function invocation ends. No-op if disabled. */
export async function flushObservability(timeoutMs = 2000): Promise<void> {
  if (!enabled) return;
  await Sentry.flush(timeoutMs);
}
