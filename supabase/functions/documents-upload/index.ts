// Documents (SOPs/manuals/recipes/menus/training/forms) upload, ported from
// packages/api/src/modules/documents/documents.controller.ts's `upload` endpoint. This is the
// ONLY way a document can be created — public.documents has no insert policy for `authenticated`
// at all (supabase/migrations/20261003003000) — because RLS cannot verify a malware scan
// happened, and that scan is a hard, fail-closed requirement here exactly as it was in legacy.
//
// Sequence: auth -> manager-role check -> filename sanitize -> base64 decode -> size cap ->
// magic-byte MIME validation -> malware scan (Cloudmersive, or clamd as a fallback) -> Storage upload -> DB row insert (rolling back
// the Storage object if the DB insert fails).
//
// NOT live-tested end to end: this sandbox has no reachable ClamAV instance, so the scan step
// itself (Deno.connect to CLAMAV_HOST) has not been exercised against a real clamd.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getCallerVenueRoles, isManager } from "../_shared/venue-auth.ts";
import { enforceRateLimit, requireEntitlement } from "../_shared/rate-limit.ts";
import {
  MAX_DOCUMENT_BYTES,
  DocumentValidationError,
  assertAllowedDocumentBytes,
  safeDocumentFileName,
} from "../_shared/document-bytes.ts";
import { assertDocumentClean, DocumentScanRejectedError, DocumentScanUnavailableError } from "../_shared/malware-scan.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

const DOCUMENT_CATEGORIES = ["sop", "manual", "recipe", "menu", "training", "form", "other"];

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64ToBytes(b64: string): Uint8Array {
  const cleaned = b64.replace(/\s/g, "");
  if (!cleaned || cleaned.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(cleaned)) {
    throw new DocumentValidationError("Document data is not valid base64");
  }
  return Uint8Array.from(atob(cleaned), (c) => c.charCodeAt(0));
}

// Largest request body accepted: base64 inflates MAX_DOCUMENT_BYTES by 4/3, plus JSON field
// overhead. ~15MB total. Enforced before the body is buffered (audit B-05).
const MAX_REQUEST_BODY_BYTES = 15 * 1024 * 1024;

class RequestTooLargeError extends Error {}

// Parses a JSON body without ever buffering more than `maxBytes`: rejects early on a declared
// Content-Length, and also counts streamed bytes so a missing/lying header (chunked transfer)
// cannot bypass the cap.
async function readBoundedJson(req: Request, maxBytes: number): Promise<unknown> {
  const declared = req.headers.get("Content-Length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isFinite(length) || length < 0) throw new SyntaxError("bad content-length");
    if (length > maxBytes) throw new RequestTooLargeError();
  }
  if (!req.body) throw new SyntaxError("empty body");
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      throw new RequestTooLargeError();
    }
    chunks.push(value);
  }
  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(merged));
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("documents-upload: unexpected error", error);
    captureException(error, { function: "documents-upload", path: new URL(req.url).pathname });
    await flushObservability();
    return jsonResponse({ error: "internal_error" }, 500);
  }
});

async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }
  // Cheap early rejection of oversized requests before any auth round-trip or buffering.
  const declaredLength = Number(req.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_REQUEST_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  let payload: {
    venue_id?: string;
    title?: string;
    file_name?: string;
    mime_type?: string;
    category?: string;
    data_base64?: string;
  };
  try {
    payload = await readBoundedJson(req, MAX_REQUEST_BODY_BYTES) as typeof payload;
  } catch (error) {
    if (error instanceof RequestTooLargeError) {
      return jsonResponse({ error: "payload_too_large" }, 413);
    }
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }
  if (payload === null || typeof payload !== "object") {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  const { venue_id, title, file_name, mime_type, category, data_base64 } = payload;
  if (!venue_id || !title?.trim() || !file_name || !mime_type || !category || !data_base64) {
    return jsonResponse(
      { error: "missing_required_fields: venue_id, title, file_name, mime_type, category, data_base64" },
      400,
    );
  }
  if (!DOCUMENT_CATEGORIES.includes(category)) {
    return jsonResponse({ error: "invalid_category" }, 400);
  }

  // Never trust venue_id/role from the client — verify the caller is an actual manager of this
  // venue via their own RLS-respecting client first. Org owners/admins hold org-level
  // memberships (venue_id null), so the lookup must cover both venue and org rows.
  const callerRoles = await getCallerVenueRoles(userClient, userData.user.id, venue_id);
  if (!callerRoles) {
    return jsonResponse({ error: "forbidden_not_a_member_of_this_venue" }, 403);
  }
  if (!isManager(callerRoles.roles)) {
    return jsonResponse({ error: "forbidden_manager_role_required" }, 403);
  }

  // Paywall + abuse controls run before the expensive decode/malware-scan work (audit B-02,
  // B-05). Rate limit fails open (logged) so a limiter outage does not block uploads.
  const limiterClient = createServiceClient();
  const entitlementBlock = await requireEntitlement(limiterClient, callerRoles.organizationId);
  if (entitlementBlock) return entitlementBlock;
  const rateBlock = await enforceRateLimit(
    limiterClient,
    `docs-upload:user:${userData.user.id}`,
    60,
    3600,
    { failOpen: true },
  );
  if (rateBlock) return rateBlock;

  let safeFileName: string;
  let data: Uint8Array;
  let trustedMime: string;
  try {
    safeFileName = safeDocumentFileName(file_name);
    data = base64ToBytes(data_base64);
    if (data.length === 0) throw new DocumentValidationError("Document is empty");
    if (data.length > MAX_DOCUMENT_BYTES) throw new DocumentValidationError("Document is too large (max 10MB)");
    trustedMime = assertAllowedDocumentBytes(data, mime_type, safeFileName);
  } catch (error) {
    if (error instanceof DocumentValidationError) {
      return jsonResponse({ error: error.message }, 400);
    }
    throw error;
  }

  try {
    await assertDocumentClean(data, safeFileName);
  } catch (error) {
    if (error instanceof DocumentScanRejectedError) {
      return jsonResponse({ error: error.message }, 400);
    }
    if (error instanceof DocumentScanUnavailableError) {
      return jsonResponse({ error: error.message }, 503);
    }
    throw error;
  }

  // Fetch organization_id up front; the Edge Function writes with the service-role client,
  // which bypasses RLS, so this join must be derived here rather than relied on from the DB.
  const { data: venue, error: venueError } = await userClient
    .from("venues")
    .select("organization_id")
    .eq("id", venue_id)
    .maybeSingle();
  if (venueError || !venue) {
    return jsonResponse({ error: "venue_not_found" }, 404);
  }

  const randomHex = Array.from(crypto.getRandomValues(new Uint8Array(8)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  // Category folded into the filename segment (not a new path segment) so this still matches
  // app_hidden.is_safe_storage_deletion_path's existing org-uuid/venue-uuid/filename regex.
  const storagePath = `${venue.organization_id}/${venue_id}/${category}--${randomHex}--${safeFileName}`;

  const serviceClient = createServiceClient();
  const { error: uploadError } = await serviceClient.storage
    .from("staff-documents")
    .upload(storagePath, data, { contentType: trustedMime, upsert: false });
  if (uploadError) {
    console.error("documents-upload: Storage upload failed", uploadError);
    return jsonResponse({ error: "document_storage_temporarily_unavailable" }, 503);
  }

  const { data: inserted, error: insertError } = await serviceClient
    .from("documents")
    .insert({
      venue_id,
      title: title.trim(),
      file_name: safeFileName,
      category,
      mime_type: trustedMime,
      size_bytes: data.length,
      storage_path: storagePath,
      uploaded_by: userData.user.id,
    })
    .select("id")
    .single();

  if (insertError || !inserted) {
    console.error("documents-upload: DB insert failed, rolling back Storage object", insertError);
    await serviceClient.storage.from("staff-documents").remove([storagePath]).catch(() => undefined);
    return jsonResponse({ error: "document_record_creation_failed" }, 500);
  }

  return jsonResponse({ id: inserted.id }, 201);
}
