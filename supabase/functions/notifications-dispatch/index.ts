// Internal push dispatch for notification_events rows created by database triggers (shift
// assigned, new staff request — see migration notification_triggers_and_dispatch). Called only
// by Postgres via pg_net, never by a client, so it is deployed with verify_jwt=false and
// authenticates with a shared secret (PUSH_DISPATCH_SECRET here, the `push_dispatch_secret`
// Vault entry on the database side) compared in constant time.
//
// The notification_events row already exists (it is what the in-app feed shows); this only
// fans it out to devices. Recipients are re-derived from the stored row, never from the
// request body, so a caller who somehow held the secret could still not target arbitrary users.
import { createServiceClient } from "../_shared/supabase-clients.ts";
import { deliverPush, type NotificationAudience } from "../_shared/push-delivery.ts";
import { captureException, flushObservability, initObservability } from "../_shared/observability.ts";

initObservability();

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function respond(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function constantTimeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return respond({ error: "method_not_allowed" }, 405);

  const expected = Deno.env.get("PUSH_DISPATCH_SECRET");
  const supplied = req.headers.get("x-dispatch-secret") ?? "";
  if (!expected || expected.length < 32 || !constantTimeEqual(supplied, expected)) {
    return respond({ error: "unauthorized" }, 401);
  }

  try {
    const { event_id } = await req.json().catch(() => ({}));
    if (typeof event_id !== "string" || !UUID_PATTERN.test(event_id)) {
      return respond({ error: "invalid_event_id" }, 400);
    }

    const admin = createServiceClient();
    const { data: event, error } = await admin
      .from("notification_events")
      .select("organization_id, venue_id, target_user_id, audience, kind, title, body, data")
      .eq("id", event_id)
      .maybeSingle();
    if (error) throw error;
    if (!event) return respond({ error: "event_not_found" }, 404);

    const result = await deliverPush(admin, {
      venueId: event.venue_id,
      organizationId: event.organization_id,
      audience: event.audience as NotificationAudience,
      targetUserIds: event.target_user_id ? [event.target_user_id] : [],
      kind: event.kind,
      title: event.title,
      body: event.body,
      data: (event.data as Record<string, unknown>) ?? {},
    });
    return respond({ ok: true, ...result });
  } catch (err) {
    console.error("notifications-dispatch failed", err);
    captureException(err, { function: "notifications-dispatch", url: req.url });
    await flushObservability();
    return respond({ error: "dispatch_failed" }, 500);
  }
});
