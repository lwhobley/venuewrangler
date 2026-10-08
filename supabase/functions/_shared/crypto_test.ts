import {
  signAttestationChallenge,
  signOAuthState,
  verifyAttestationChallenge,
  verifyOAuthState,
} from "./crypto.ts";

const key = btoa("k".repeat(32));

Deno.test("OAuth state verifier treats malformed tokens as invalid", async () => {
  const state = await signOAuthState({ venue_id: "venue", user_id: "user" }, key);
  if ((await verifyOAuthState(state, key))?.venue_id !== "venue") {
    throw new Error("valid state rejected");
  }
  if (await verifyOAuthState("not-base64.%%%%", key) !== null) {
    throw new Error("malformed state accepted");
  }
});

Deno.test("attestation verifier treats malformed challenges as invalid", async () => {
  const challenge = await signAttestationChallenge("user", "device", key);
  if (!await verifyAttestationChallenge(challenge.token, "user", "device", key)) {
    throw new Error("valid challenge rejected");
  }
  if (await verifyAttestationChallenge("not-base64.%%%%", "user", "device", key) !== null) {
    throw new Error("malformed challenge accepted");
  }
});
