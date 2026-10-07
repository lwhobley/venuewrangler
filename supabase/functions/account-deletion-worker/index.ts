// Finishes a self-serve account deletion by deleting the auth.users row, which has no
// SQL-level equivalent (Supabase's Auth Admin API is the only way to do this without
// bypassing GoTrue's own session/refresh-token bookkeeping). Called only by Postgres via
// pg_net — either immediately from public.request_account_deletion, or later by the
// app_hidden.sweep_account_deletion_jobs retry sweep — never by a client, so it is deployed
// with verify_jwt=false and authenticates with a shared secret
// (ACCOUNT_DELETION_DISPATCH_SECRET here, the `account_deletion_dispatch_secret` Vault entry
// on the database side) compared in constant time, same pattern as notifications-dispatch.
//
// All the synchronous, RLS-governed cleanup (wage-record retention, anonymizing attribution,
// dropping memberships/profile/HR data) already happened inside request_account_deletion's
// own transaction before this job was ever queued — by the time this runs, the account is
// already functionally gone from the product. This only removes the login credential itself.
import { createServiceClient } from "../_shared/supabase-clients.ts";
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

  const expected = Deno.env.get("ACCOUNT_DELETION_DISPATCH_SECRET");
  const supplied = req.headers.get("x-dispatch-secret") ?? "";
  if (!expected || expected.length < 32 || !constantTimeEqual(supplied, expected)) {
    return respond({ error: "unauthorized" }, 401);
  }

  const { job_id } = await req.json().catch(() => ({}));
  if (typeof job_id !== "string" || !UUID_PATTERN.test(job_id)) {
    return respond({ error: "invalid_job_id" }, 400);
  }

  const admin = createServiceClient();

  let job: { id: string; user_id: string; status: string; attempts: number } | null;
  try {
    const { data, error: fetchError } = await admin
      .from("account_deletion_jobs")
      .select("id, user_id, status, attempts")
      .eq("id", job_id)
      .maybeSingle();
    if (fetchError) throw fetchError;
    job = data;
  } catch (err) {
    // Can't read the queue at all: nothing to mark failed. The retry sweep will pick the job
    // up again once the database is reachable.
    console.error("account-deletion-worker could not load job", err);
    captureException(err, { function: "account-deletion-worker", job_id });
    await flushObservability();
    return respond({ error: "job_lookup_failed" }, 500);
  }
  if (!job) return respond({ error: "job_not_found" }, 404);
  if (job.status === "completed" || job.status === "dead") {
    return respond({ ok: true, already: job.status });
  }

  // 'processing' is only a lease: if this invocation dies before reporting a result, the
  // retry sweep (app_hidden.sweep_account_deletion_jobs) reclaims the job after 15 minutes.
  const nextAttempts = job.attempts + 1;
  await admin
    .from("account_deletion_jobs")
    .update({ status: "processing", attempts: nextAttempts })
    .eq("id", job_id);

  try {
    // Not-found is treated as success: the account may already have been deleted by a prior
    // attempt whose response never made it back (net.http_post is fire-and-forget).
    const { error } = await admin.auth.admin.deleteUser(job.user_id);
    if (error && error.status !== 404) throw error;

    await admin
      .from("account_deletion_jobs")
      .update({ status: "completed", completed_at: new Date().toISOString(), last_error: null })
      .eq("id", job_id);
    return respond({ ok: true });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await admin
      .from("account_deletion_jobs")
      .update({
        status: nextAttempts >= 10 ? "dead" : "failed",
        last_error: message.slice(0, 1000),
      })
      .eq("id", job_id);
    console.error("account-deletion-worker failed", err);
    captureException(err, { function: "account-deletion-worker", job_id });
    await flushObservability();
    return respond({ error: "deletion_failed" }, 500);
  }
});
