// Device attestation, in observe mode per the migration plan's hard requirement: this
// function NEVER blocks or rejects a request based on an attestation verdict — it only
// records one, for later analysis once the product is ready to move toward `enforce`. Always
// returns 200 (barring auth/validation failures) regardless of what it found.
//
// Android (Play Integrity): the server decodes the token with Google and checks
// its package, fresh request details, and a single-use server challenge. The
// Flutter Android client has not yet implemented the token request flow.
//
// iOS (App Attest): cryptographically verified — see ../_shared/app-attest.ts for the full
// 9-step algorithm (CBOR/COSE parsing, certificate chain validation against Apple's real App
// Attestation Root CA, nonce/rpIdHash/counter/aaguid/credentialId checks), implemented with a
// hand-rolled DER parser and Web Crypto since Deno's edge runtime has no Node `crypto` module.
//
// Both platforms use a signed challenge bound to the caller and device. The
// attestation_challenges table records the nonce for one-time consumption. iOS
// sends it to App Attest; Android binds it to Play Integrity's requestHash or
// classic nonce. The iOS path remains fail-open if recording the challenge
// fails, consistent with observe mode; Android requires a recorded nonce.
import { corsHeaders, handleCorsPreflight } from "../_shared/cors.ts";
import {
  createServiceClient,
  createUserClient,
} from "../_shared/supabase-clients.ts";
import { getGoogleAccessToken } from "../_shared/google-auth.ts";
import {
  sha256Hex,
  signAttestationChallenge,
  verifyAttestationChallenge,
} from "../_shared/crypto.ts";
import { verifyAppAttest } from "../_shared/app-attest.ts";
import { matchesPlayIntegrityRequest } from "../_shared/play-integrity.ts";
import {
  captureException,
  flushObservability,
  initObservability,
} from "../_shared/observability.ts";

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

async function consumeAttestationChallenge(
  // deno-lint-ignore no-explicit-any
  serviceClient: any,
  nonceHash: string,
): Promise<"consumed" | "already_used" | "not_found"> {
  // Atomic claim: only succeeds (updates a row) the first time it's called for a given
  // nonce_hash, since the WHERE clause excludes rows already marked consumed. A second call
  // with the same hash updates zero rows, which is exactly the replay case this guards against.
  const { data, error } = await serviceClient
    .from("attestation_challenges")
    .update({ consumed_at: new Date().toISOString() })
    .eq("nonce_hash", nonceHash)
    .is("consumed_at", null)
    .gt("expires_at", new Date().toISOString())
    .select("id");

  if (error) {
    console.error("failed to consume attestation challenge", error);
    return "not_found";
  }
  if (data && data.length > 0) return "consumed";

  // Zero rows updated: either no row with this hash exists (recording failed at issuance, or
  // this predates the attestation_challenges table), or one exists but is already consumed or
  // expired. Distinguish the two so an issuance-time recording failure doesn't become a hard
  // verification failure.
  const { data: existing } = await serviceClient
    .from("attestation_challenges")
    .select("consumed_at")
    .eq("nonce_hash", nonceHash)
    .maybeSingle();

  return existing?.consumed_at ? "already_used" : "not_found";
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
    const challengeSigningKey = Deno.env.get(
      "APP_ATTEST_CHALLENGE_SIGNING_KEY",
    );
    if (!challengeSigningKey) {
      return jsonResponse({ error: "app_attest_not_configured" }, 503);
    }
    const { token, nonceBytes } = await signAttestationChallenge(
      userData.user.id,
      payload.device_id,
      challengeSigningKey,
    );
    // Record the challenge server-side so it can be consumed exactly once on verification —
    // closes the replay-window gap the signed token alone can't (see attestation_challenges
    // migration). Recording failure is non-fatal: the challenge still works, it just can't be
    // tracked as single-use, same fail-open posture as this function's observe mode generally.
    const { error: recordError } = await createServiceClient().from(
      "attestation_challenges",
    ).insert({
      user_id: userData.user.id,
      device_id: payload.device_id,
      nonce_hash: await sha256Hex(nonceBytes),
      expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
    });
    if (recordError) {
      console.error("failed to record attestation challenge", recordError);
    }
    return jsonResponse({ challenge: token });
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
    if (!payload.integrity_token || !payload.challenge) {
      return jsonResponse(
        { error: "missing_integrity_token_or_challenge" },
        400,
      );
    }
    const packageName = Deno.env.get("PLAY_INTEGRITY_PACKAGE_NAME");
    const serviceAccountJson = Deno.env.get(
      "PLAY_INTEGRITY_SERVICE_ACCOUNT_JSON",
    );
    const challengeSigningKey = Deno.env.get(
      "APP_ATTEST_CHALLENGE_SIGNING_KEY",
    );

    if (!packageName || !serviceAccountJson || !challengeSigningKey) {
      console.error("Play Integrity is not configured");
      detail = { error: "play_integrity_not_configured" };
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
              body: JSON.stringify({
                integrity_token: payload.integrity_token,
              }),
            },
          );

          if (!integrityResponse.ok) {
            console.error(
              "Play Integrity call failed",
              await integrityResponse.text(),
            );
            detail = { error: "play_integrity_call_failed" };
          } else {
            const integrityResult = await integrityResponse.json();
            const appVerdict = integrityResult.tokenPayloadExternal
              ?.appIntegrity?.appRecognitionVerdict;
            const deviceVerdicts =
              integrityResult.tokenPayloadExternal?.deviceIntegrity
                ?.deviceRecognitionVerdict ?? [];
            const requestDetails = integrityResult.tokenPayloadExternal
              ?.requestDetails;
            const nonceHash = await sha256Hex(nonceBytes);
            const requestMatches = await matchesPlayIntegrityRequest(
              requestDetails,
              packageName,
              nonceBytes,
            );
            const claim = requestMatches
              ? await consumeAttestationChallenge(serviceClient, nonceHash)
              : "not_found";
            status = requestMatches && claim === "consumed" &&
                appVerdict === "PLAY_RECOGNIZED" &&
                deviceVerdicts.includes("MEETS_DEVICE_INTEGRITY")
              ? "valid"
              : "invalid";
            detail = {
              appVerdict,
              deviceVerdicts,
              requestMatches,
              challengeClaim: claim,
            };
          }
        } catch (err) {
          console.error("Play Integrity verification error", err);
          detail = { error: "play_integrity_exception" };
        }
      }
    }
  } else {
    // iOS — real cryptographic verification via app-attest.ts.
    if (!payload.key_id || !payload.attestation_object || !payload.challenge) {
      return jsonResponse({
        error: "missing_key_id_attestation_object_or_challenge",
      }, 400);
    }

    const challengeSigningKey = Deno.env.get(
      "APP_ATTEST_CHALLENGE_SIGNING_KEY",
    );
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
      } else if (
        (await consumeAttestationChallenge(
          serviceClient,
          await sha256Hex(nonceBytes),
        )) === "already_used"
      ) {
        // The signed token itself is still valid and unexpired, but this exact nonce was already
        // consumed by a prior verification attempt — the actual replay case this table exists to
        // catch. A row that was never found (e.g. the insert at issuance time failed) is treated
        // as pass-through rather than a hard failure, matching this function's fail-open,
        // observe-only posture elsewhere.
        status = "invalid";
        detail = { error: "challenge_already_used" };
      } else {
        try {
          const result = await verifyAppAttest({
            attestationObject: base64ToBytes(payload.attestation_object),
            challenge: nonceBytes,
            keyId: payload.key_id,
            bundleIdentifier: bundleId,
            teamIdentifier: teamId,
            // Non-production builds (TestFlight/dev) attest with the development AAGUID;
            // allowed in observe/log mode only — enforce mode requires production.
            allowDevelopmentEnvironment: mode !== "enforce",
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

  const { error: insertError } = await serviceClient.from("device_attestations")
    .insert({
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
