// Storage object bytes must be removed through the Storage API. Postgres deletes from
// storage.objects only affect metadata and can leave inaccessible object data behind.
import { createServiceClient } from "../_shared/supabase-clients.ts";

function respond(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function constantTimeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const x = encoder.encode(a);
  const y = encoder.encode(b);
  let difference = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    difference |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return respond({ error: "method_not_allowed" }, 405);

  const expected = Deno.env.get("STORAGE_DELETION_DISPATCH_SECRET");
  const supplied = request.headers.get("x-dispatch-secret") ?? "";
  if (!expected || expected.length < 32 || !constantTimeEqual(supplied, expected)) {
    return respond({ error: "unauthorized" }, 401);
  }

  // A literal `null` (or array) body parses but has no fields; treat it as an empty body.
  const parsed: unknown = await request.json().catch(() => null);
  const body: Record<string, unknown> =
    parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  const batchSize = Number.isInteger(body.batch_size) ? body.batch_size as number : 25;
  if (batchSize < 1 || batchSize > 100) return respond({ error: "invalid_batch_size" }, 400);

  const admin = createServiceClient();
  const { data: jobs, error: claimError } = await admin.rpc("claim_storage_deletion_jobs", {
    p_limit: batchSize,
  });
  if (claimError) {
    console.error("storage deletion batch claim failed", claimError.code);
    return respond({ error: "claim_failed" }, 500);
  }

  let completed = 0;
  let failed = 0;
  for (const job of (jobs ?? []) as Array<{
    id: string;
    bucket_id: string;
    object_path: string;
    attempts: number;
  }>) {
    try {
      const { error } = await admin.storage.from(job.bucket_id).remove([job.object_path]);
      if (error) throw error;

      const { data, error: updateError } = await admin
        .from("storage_deletion_jobs")
        .update({ status: "completed", completed_at: new Date().toISOString(), last_error: null,
          updated_at: new Date().toISOString() })
        .eq("id", job.id)
        .eq("status", "processing")
        .eq("attempts", job.attempts)
        .select("id")
        .maybeSingle();
      if (updateError) throw updateError;
      if (!data) throw new Error("Storage deletion claim was lost before completion");
      completed++;
    } catch (error) {
      const status = job.attempts >= 10 ? "dead" : "failed";
      const { error: updateError } = await admin
        .from("storage_deletion_jobs")
        .update({ status, last_error: "Storage API deletion failed", updated_at: new Date().toISOString() })
        .eq("id", job.id)
        .eq("status", "processing")
        .eq("attempts", job.attempts);
      if (updateError) console.error("storage deletion failure could not be persisted", updateError.code);
      console.error("storage object removal failed", error instanceof Error ? error.name : "unknown");
      failed++;
    }
  }

  return respond({ processed: (jobs ?? []).length, completed, failed });
});
