// Device attestation, in observe mode per the migration plan's hard requirement: this
// function NEVER blocks or rejects a request based on an attestation verdict — it only
// records one, for later analysis once the product is ready to move toward `enforce`. Always
// returns 200 (barring auth/validation failures) regardless of what it found.
//
// Android (Play Integrity): fully implemented — exchanges PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON
// for a Google OAuth2 token (see ../_shared/google-auth.ts) and calls the real
// decodeIntegrityToken API, so `status` reflects an actual verdict from Google.
//
// iOS (App Attest): cryptographically verified — see ../_shared/app-attest.ts for the full
// 9-step algorithm (CBOR/COSE parsing, certificate chain validation against Apple's real App
// Attestation Root CA, nonce/rpIdHash/counter/aaguid/credentialId checks), implemented with a
// hand-rolled DER parser and Web Crypto since Deno's edge runtime has no Node `crypto` module.
//
// Two-step flow, since App Attest needs a server-issued challenge before the client can attest:
//   1. POST { action: "challenge", platform: "ios", device_id } -> { challenge }. The challenge
//      is a signed, timestamped token (see signAttestationChallenge in ../_shared/crypto.ts),
//      bound to this exact user and device_id, not a server-stored single-use nonce — there is
//      no attestation_challenges table. That means a captured, still-fresh challenge+attestation
//      pair could in principle be replayed within its 5-minute TTL; closing that fully would
//      need real server-side challenge storage, which is a reasonable follow-up but out of
//      scope for "implement the verification" and is flagged here rather than silently assumed
//      away. observe mode's own purpose (recording, never blocking) makes this an acceptable
//      interim gap, not one to carry into `enforce` mode unexamined.
//   2. POST { platform: "ios", device_id, key_id, attestation_object, challenge } -> verified
//      and recorded.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import { createServiceClient, createUserClient } from "../_shared/supabase-clients.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";
import { signAttestationChallenge, verifyAttestationChallenge } from "../_shared/crypto.ts";
import { verifyAppAttest } from "../_shared/app-attest.ts";
import { initObservability, captureException, flushObservability } from "../_shared/observability.ts";

initObservability();

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

Deno.serve(async (req) => {
  const preflight = handleCorsPreflight(req);
  if (preflight) return preflight;

  try {
    return await handleRequest(req);
  } catch (error) {
    console.error("unexpected error", error);
    captureException(error, { function: "device-attestation", url: req.url });
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
  const userClient = createUserClient(authHeader);
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return jsonResponse({ error: "invalid_or_expired_session" }, 401);
  }

  let payload: {
    action?: string;
    platform?: string;
    device_id?: string;
    integrity_token?: string;
    key_id?: string;
    attestation_object?: string;
    challenge?: string;
  };
  try {
    payload = await req.json();
  } catch {
    return jsonResponse({ error: "invalid_json_body" }, 400);
  }

  if (!payload.device_id) {
    return jsonResponse({ error: "missing_device_id" }, 400);
  }

  // Step 1 of the iOS flow: issue a signed challenge. Not gated by DEVICE_ATTESTATION_MODE
  // since issuing a challenge records nothing and blocks nothing either way.
  if (payload.action === "challenge") {
    const challengeSigningKey = Deno.env.get("APP_ATTEST_CHALLENGE_SIGNING_KEY");
    if (!challengeSigningKey) {
      return jsonResponse({ error: "app_attest_not_configured" }, 503);
    }
    const challenge = await signAttestationChallenge(userData.user.id, payload.device_id, challengeSigningKey);
    return jsonResponse({ challenge });
  }

  const mode = Deno.env.get("DEVICE_ATTESTATION_MODE") ?? "observe";
  if (mode === "off") {
    return jsonResponse({ recorded: false, mode: "off" });
  }

  if (payload.platform !== "ios" && payload.platform !== "android") {
    return jsonResponse({ error: "invalid_platform" }, 400);
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
    // iOS — real cryptographic verification via app-attest.ts.
    if (!payload.key_id || !payload.attestation_object || !payload.challenge) {
      return jsonResponse({ error: "missing_key_id_attestation_object_or_challenge" }, 400);
    }

    const challengeSigningKey = Deno.env.get("APP_ATTEST_CHALLENGE_SIGNING_KEY");
    const teamId = Deno.env.get("APP_ATTEST_TEAM_ID");
    const bundleId = Deno.env.get("APP_ATTEST_BUNDLE_ID");

    if (!challengeSigningKey || !teamId || !bundleId) {
      console.error("App Attest is not configured");
      detail = { error: "app_attest_not_configured" };
    } else {
      const nonceBytes = await verifyAttestationChallenge(
        payload.challenge,
        userData.user.id,
        payload.device_id,
        challengeSigningKey,
      );

      if (!nonceBytes) {
        status = "invalid";
        detail = { error: "challenge_invalid_or_expired" };
      } else {
        try {
          const result = await verifyAppAttest({
            attestationObject: base64ToBytes(payload.attestation_object),
            challenge: nonceBytes,
            keyId: payload.key_id,
            bundleIdentifier: bundleId,
            teamIdentifier: teamId,
            // Non-production builds (TestFlight/dev) attest with the development AAGUID;
            // allow it everywhere for now since this is observe-mode only — tighten this to
            // production-only once this feature is actually used to gate anything.
            allowDevelopmentEnvironment: true,
          });
          status = "valid";
          detail = { environment: result.environment, key_id: result.keyId };
        } catch (err) {
          status = "invalid";
          detail = { error: err instanceof Error ? err.message : String(err) };
        }
      }
    }
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
}
