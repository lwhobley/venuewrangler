// Device attestation, in observe mode per the migration plan's hard requirement: this
// function NEVER blocks or rejects a request based on an attestation verdict — it only
// records one, for later analysis once the product is ready to move toward `enforce`. Always
// returns 200 (barring auth/validation failures) regardless of what it found.
//
// Android (Play Integrity): fully implemented — exchanges PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON
// for a Google OAuth2 token (see ../_shared/google-auth.ts) and calls the real
// decodeIntegrityToken API, so `status` reflects an actual verdict from Google.
//
// iOS (App Attest): NOT cryptographically verified. Real verification means parsing a CBOR/
// COSE attestation object and validating its certificate chain against Apple's App Attest
// root CA — a non-trivial parser this environment has no verified CBOR library for. The
// submitted assertion is stored as-is (status='observed') so the telemetry pipeline and
// schema are in place; implement real verification as a follow-up before this ever moves
// past observe mode for iOS.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const mode = Deno.env.get("DEVICE_ATTESTATION_MODE") ?? "observe";
  if (mode === "off") {
    return jsonResponse({ recorded: false, mode: "off" });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "missing_authorization_header" }, 401);
  }
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  let payload: {
    platform?: string;
    device_id?: string;
    integrity_token?: string;
    key_id?: string;
    attestation_object?: string;
  };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  if (payload.platform !== "ios" && payload.platform !== "android") {
    return jsonResponse({ error: "invalid_platform" }, 400);
  }
  if (!payload.device_id) {
    return jsonResponse({ error: "missing_device_id" }, 400);
  }

  const serviceClient = createServiceClient();
  let status: "observed" | "valid" | "invalid" = "observed";
  let detail: Record<string, unknown> = {};

  if (payload.platform === "android") {
    if (!payload.integrity_token) {
      return jsonResponse({ error: "missing_integrity_token" }, 400);
    }
    const packageName = Deno.env.get("PLAY_INTEGRITY_PACKAGE_NAME");
    const serviceAccountJson = Deno.env.get("PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON");

    if (!packageName || !serviceAccountJson) {
      console.error("Play Integrity is not configured");
      detail = { error: "play_integrity_not_configured" };
    } else {
      try {
        const accessToken = await getGoogleAccessToken(
          serviceAccountJson,
          "https://www.googleapis.com/auth/playintegrity",
        );
        const integrityResponse = await fetch(
          `https://playintegrity.googleapis.com/v1/${packageName}:decodeIntegrityToken`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ integrity_token: payload.integrity_token }),
          },
        );

        if (!integrityResponse.ok) {
          console.error("Play Integrity call failed", await integrityResponse.text());
          detail = { error: "play_integrity_call_failed" };
        } else {
          const integrityResult = await integrityResponse.json();
          const appVerdict =
            integrityResult.tokenPayloadExternal?.appIntegrity?.appRecognitionVerdict;
          const deviceVerdicts =
            integrityResult.tokenPayloadExternal?.deviceIntegrity?.deviceRecognitionVerdict ?? [];
          status =
            appVerdict === "PLAY_RECOGNIZED" && deviceVerdicts.includes("MEETS_DEVICE_INTEGRITY")
              ? "valid"
              : "invalid";
          detail = { appVerdict, deviceVerdicts };
        }
      } catch (err) {
        console.error("Play Integrity verification error", err);
        detail = { error: "play_integrity_exception" };
      }
    }
  } else {
    // iOS — recorded only, see the header comment above.
    detail = {
      key_id: payload.key_id ?? null,
      attestation_object_length: payload.attestation_object?.length ?? 0,
      note: "not cryptographically verified in this build",
    };
  }

  const { error: insertError } = await serviceClient.from("device_attestations").insert({
    user_id: userData.user.id,
    platform: payload.platform,
    device_id: payload.device_id,
    status,
    detail,
  });

  if (insertError) {
    console.error("failed to record device attestation", insertError);
  }

  // Always a success response: observe mode never blocks, regardless of status or whether the
  // insert itself succeeded.
  return jsonResponse({ recorded: !insertError, mode, status });
});
