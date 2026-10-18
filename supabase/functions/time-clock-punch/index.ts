// Records clock-in / clock-out punches with proof of device (audit F-01).
//
// The Flutter app used to insert straight into `time_entries`, so the geofence / accuracy /
// "mocked" checks ran on numbers the client chose. This function is the attested path:
//
//   POST { action: "challenge" }
//     -> { nonce, expires_in }          single-use server nonce, valid ~2 minutes
//   POST { action: "punch", platform: "ios" | "android", payload_json, evidence }
//     -> { status: "verified" | "unverified", entry }
//
// `payload_json` is the exact string the app hashed: {"v":1,"kind","venue_id","lat","lng",
// "accuracy_m","mocked","nonce","ts"}. `evidence` is
//   iOS      { key_id, assertion }          App Attest assertion with clientDataHash = SHA-256(payload_json)
//   Android  { integrity_token }            Play Integrity token with requestHash = hex SHA-256(payload_json)
// The server consumes the nonce (replay), checks the timestamp, verifies the evidence, then calls
// record_attested_punch(), which re-runs every database check (membership, geofence, accuracy,
// replay of identical fixes) and stamps the entry attested only if verification passed.
//
// TIME_CLOCK_ATTESTATION_MODE:
//   off      do not verify; punches are recorded unattested
//   observe  (default) verify; a failed or missing proof still records the punch as UNATTESTED so
//            managers can review it. Nobody is locked out while client builds roll out.
//   enforce  a failed or missing proof is refused (403). Pair with
//            platform_settings.require_attested_punches = true so the direct database path is
//            closed as well.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { enforceRateLimit } from "../_shared/rate-limit.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";
import {
  base64ToBytes,
  evaluatePlayIntegrityForPunch,
  type PlayIntegrityDecoded,
  parsePunchPayload,
  PunchPayloadError,
  payloadHashHex,
  sha256Bytes,
  utf8,
  verifyAppAttestAssertion,
} from "../_shared/punch-attestation.ts";
import { sha256Hex } from "../_shared/crypto.ts";

initObservability();

type Mode = "off" | "observe" | "enforce";

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function attestationMode(): Mode {
  const raw = (Deno.env.get("TIME_CLOCK_ATTESTATION_MODE") ?? "observe").toLowerCase();
  return raw === "off" || raw === "enforce" ? raw : "observe";
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;
  try {
    return await handle(req);
  } catch (error) {
    console.error("time-clock-punch: unexpected error", error);
    captureException(error, { function: "time-clock-punch" });
    await flushObservability();
    return json({ error: "internal_error" }, 500);
  }
});

async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing_authorization_header" }, 401);
  const contentLength = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > 16 * 1024) return json({ error: "payload_too_large" }, 413);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json_body" }, 400);
  }

  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: "invalid_or_expired_session" }, 401);
  const userId = userData.user.id;
  const serviceClient = createServiceClient();

  if (body.action === "challenge") {
    const limited = await enforceRateLimit(serviceClient, `punch-challenge:${userId}`, 120, 3600, { failOpen: true });
    if (limited) return limited;
    const nonce = base64Url(crypto.getRandomValues(new Uint8Array(32)));
    const { error } = await serviceClient.rpc("issue_punch_nonce", {
      p_user_id: userId,
      p_nonce_hash: await sha256Hex(utf8(nonce)),
      p_ttl_seconds: 120,
    });
    if (error) {
      console.error("issue_punch_nonce failed", error);
      return json({ error: "challenge_unavailable" }, 503);
    }
    return json({ nonce, expires_in: 120, mode: attestationMode() });
  }

  if (body.action !== "punch") return json({ error: "unknown_action" }, 400);

  const limited = await enforceRateLimit(serviceClient, `punch:${userId}`, 240, 3600, { failOpen: true });
  if (limited) return limited;

  let payload;
  try {
    payload = parsePunchPayload(body.payload_json);
  } catch (error) {
    if (error instanceof PunchPayloadError) return json({ error: error.message }, 400);
    throw error;
  }
  const payloadJson = body.payload_json as string;

  // Single-use nonce: spent before any other work so a failed verification cannot be retried
  // with the same proof.
  const { data: nonceOk, error: nonceError } = await serviceClient.rpc("consume_punch_nonce", {
    p_user_id: userId,
    p_nonce_hash: await sha256Hex(utf8(payload.nonce)),
  });
  if (nonceError) {
    console.error("consume_punch_nonce failed", nonceError);
    return json({ error: "challenge_unavailable" }, 503);
  }
  if (nonceOk !== true) return json({ error: "nonce_invalid_or_expired" }, 409);

  const mode = attestationMode();
  let attested = false;
  let reason = "not_verified";
  if (mode !== "off") {
    const platform = body.platform;
    const evidence = (typeof body.evidence === "object" && body.evidence !== null ? body.evidence : {}) as Record<string, unknown>;
    try {
      if (platform === "ios") {
        ({ attested, reason } = await verifyIos(serviceClient, userId, payloadJson, evidence));
      } else if (platform === "android") {
        ({ attested, reason } = await verifyAndroid(payloadJson, evidence));
      } else {
        reason = "platform_missing";
      }
    } catch (error) {
      console.error("time-clock-punch: verification error", error);
      reason = "verification_error";
    }
  }

  if (!attested && mode === "enforce") {
    return json({ error: "attestation_failed", reason }, 403);
  }

  const { data: entry, error: punchError } = await serviceClient.rpc("record_attested_punch", {
    p_user_id: userId,
    p_venue_id: payload.venue_id,
    p_kind: payload.kind,
    p_lat: payload.lat,
    p_lng: payload.lng,
    p_accuracy_m: payload.accuracy_m,
    p_mocked: payload.mocked,
    p_attested: attested,
  });
  if (punchError) return punchErrorResponse(punchError);

  return json({ status: attested ? "verified" : "unverified", reason: attested ? "verified" : reason, entry });
}

function punchErrorResponse(error: { code?: string; message?: string }): Response {
  const message = error.message ?? "";
  switch (error.code) {
    case "42501":
      if (/geofence/i.test(message)) return json({ error: "outside_geofence" }, 403);
      if (/accuracy/i.test(message)) return json({ error: "location_accuracy_too_low" }, 403);
      if (/mock/i.test(message)) return json({ error: "mocked_location" }, 403);
      if (/identical to an earlier punch/i.test(message)) return json({ error: "location_replayed" }, 403);
      if (/attested_punch_required/.test(message)) return json({ error: "attested_punch_required" }, 403);
      return json({ error: "forbidden" }, 403);
    case "P0002":
      return json({ error: "no_open_punch" }, 409);
    case "23505":
      return json({ error: "already_clocked_in" }, 409);
    case "22023":
      return json({ error: "invalid_punch" }, 400);
    default:
      console.error("record_attested_punch failed", error);
      return json({ error: "punch_failed" }, 500);
  }
}

async function verifyIos(
  // deno-lint-ignore no-explicit-any
  serviceClient: any,
  userId: string,
  payloadJson: string,
  evidence: Record<string, unknown>,
): Promise<{ attested: boolean; reason: string }> {
  const keyId = evidence.key_id;
  const assertionB64 = evidence.assertion;
  if (typeof keyId !== "string" || typeof assertionB64 !== "string" || keyId.length > 200 || assertionB64.length > 8192) {
    return { attested: false, reason: "evidence_missing" };
  }
  const teamId = Deno.env.get("APP_ATTEST_TEAM_ID");
  const bundleId = Deno.env.get("APP_ATTEST_BUNDLE_ID");
  if (!teamId || !bundleId) return { attested: false, reason: "app_attest_not_configured" };

  const { data: key, error } = await serviceClient
    .from("device_attestation_keys")
    .select("public_key_spki, counter")
    .eq("user_id", userId)
    .eq("platform", "ios")
    .eq("key_id", keyId)
    .is("revoked_at", null)
    .maybeSingle();
  if (error) {
    console.error("device_attestation_keys lookup failed", error);
    return { attested: false, reason: "key_lookup_failed" };
  }
  if (!key) return { attested: false, reason: "unknown_key" };

  let counter: number;
  try {
    ({ counter } = await verifyAppAttestAssertion({
      assertion: base64ToBytes(assertionB64),
      clientDataHash: await sha256Bytes(utf8(payloadJson)),
      publicKeySpki: base64ToBytes(key.public_key_spki as string),
      storedCounter: Number(key.counter),
      expectedRpIdHash: await sha256Bytes(utf8(`${teamId}.${bundleId}`)),
    }));
  } catch (verificationError) {
    return {
      attested: false,
      reason: verificationError instanceof Error ? verificationError.message.replace(/^assertion: /, "assertion_") : "assertion_invalid",
    };
  }

  // Compare-and-set: of two requests presenting the same counter, only one advances it.
  const { data: advanced, error: advanceError } = await serviceClient.rpc("advance_attestation_counter", {
    p_user_id: userId,
    p_platform: "ios",
    p_key_id: keyId,
    p_counter: counter,
  });
  if (advanceError || advanced !== true) return { attested: false, reason: "assertion_counter_replay" };
  return { attested: true, reason: "verified" };
}

async function verifyAndroid(
  payloadJson: string,
  evidence: Record<string, unknown>,
): Promise<{ attested: boolean; reason: string }> {
  const token = evidence.integrity_token;
  if (typeof token !== "string" || token.length === 0 || token.length > 16_384) {
    return { attested: false, reason: "evidence_missing" };
  }
  const packageName = Deno.env.get("PLAY_INTEGRITY_PACKAGE_NAME");
  const serviceAccountJson = Deno.env.get("PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON");
  if (!packageName || !serviceAccountJson) return { attested: false, reason: "play_integrity_not_configured" };

  const accessToken = await getGoogleAccessToken(serviceAccountJson, "https://www.googleapis.com/auth/playintegrity");
  const response = await fetch(`https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ integrity_token: token }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    console.error("Play Integrity call failed", response.status);
    return { attested: false, reason: "play_integrity_call_failed" };
  }
  const decoded = (await response.json()) as PlayIntegrityDecoded;
  const verdict = evaluatePlayIntegrityForPunch(decoded, packageName, await payloadHashHex(payloadJson));
  return { attested: verdict.ok, reason: verdict.reason };
}
