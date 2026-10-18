import {
  decryptToken,
  encryptToken,
  signAttestationChallenge,
  signOAuthState,
  verifyAttestationChallenge,
  verifyOAuthState,
} from "./crypto.ts";

const key = btoa("k".repeat(32));

Deno.test("OAuth state verifier treats malformed tokens as invalid", async () => {
  const state = await signOAuthState({ venue_id: "venue", user_id: "user", aud: "square" }, key);
  if ((await verifyOAuthState(state, key, "square"))?.venue_id !== "venue") {
    throw new Error("valid state rejected");
  }
  if (await verifyOAuthState("not-base64.%%%%", key, "square") !== null) {
    throw new Error("malformed state accepted");
  }
});

Deno.test("OAuth state is rejected at a different provider's callback", async () => {
  const state = await signOAuthState({ venue_id: "venue", user_id: "user", aud: "gusto" }, key);
  if (await verifyOAuthState(state, key, "square") !== null) {
    throw new Error("state for gusto accepted at square callback");
  }
});

Deno.test("every signed OAuth state carries a fresh random uuid nonce", async () => {
  const a = await verifyOAuthState(
    await signOAuthState({ venue_id: "venue", user_id: "user", aud: "square" }, key),
    key,
    "square",
  );
  const b = await verifyOAuthState(
    await signOAuthState({ venue_id: "venue", user_id: "user", aud: "square" }, key),
    key,
    "square",
  );
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!a || !b || !uuid.test(a.nonce) || !uuid.test(b.nonce)) throw new Error("nonce missing");
  if (a.nonce === b.nonce) throw new Error("nonce reused across states");
});

Deno.test("OAuth state without a nonce (pre-redesign format) is rejected", async () => {
  // Re-sign a payload that has no nonce, using the real key, as an old in-flight state would.
  const payload = btoa(JSON.stringify({
    venue_id: "venue",
    user_id: "user",
    aud: "square",
    purpose: "payroll_connect",
    issued_at: Date.now(),
  }));
  const hmacKey = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(atob(key), (c) => c.charCodeAt(0)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", hmacKey, new TextEncoder().encode(payload)),
  );
  const token = `${payload}.${btoa(String.fromCharCode(...signature))}`;
  if (await verifyOAuthState(token, key, "square") !== null) {
    throw new Error("nonce-less state accepted");
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

const context = { venueId: "11111111-1111-1111-1111-111111111111", provider: "square" } as const;

Deno.test("encryptToken writes the versioned v1 format and round-trips", async () => {
  const encoded = await encryptToken("secret-token", key, context);
  const parts = encoded.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") throw new Error(`unexpected format: ${encoded}`);
  if (await decryptToken(encoded, key, context) !== "secret-token") {
    throw new Error("v1 round trip failed");
  }
});

Deno.test("v1 ciphertext is bound to its venue and provider", async () => {
  const encoded = await encryptToken("secret-token", key, context);
  const wrongContexts = [
    { venueId: "22222222-2222-2222-2222-222222222222", provider: "square" },
    { venueId: context.venueId, provider: "gusto" },
  ] as const;
  for (const wrong of wrongContexts) {
    let threw = false;
    try {
      await decryptToken(encoded, key, wrong);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error("v1 ciphertext decrypted under the wrong context");
  }
  let threwWithoutContext = false;
  try {
    await decryptToken(encoded, key);
  } catch {
    threwWithoutContext = true;
  }
  if (!threwWithoutContext) throw new Error("v1 ciphertext decrypted without a context");
});

Deno.test("a tampered v1 ciphertext fails authentication", async () => {
  const [version, iv, ct] = (await encryptToken("secret-token", key, context)).split(".");
  const bytes = Uint8Array.from(atob(ct), (c) => c.charCodeAt(0));
  bytes[0] ^= 0xff;
  const tampered = `${version}.${iv}.${btoa(String.fromCharCode(...bytes))}`;
  let threw = false;
  try {
    await decryptToken(tampered, key, context);
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("tampered ciphertext accepted");
});

Deno.test("decryptToken still accepts the legacy unversioned <iv>.<ct> format", async () => {
  // Build a legacy value exactly the way the pre-versioning encryptToken did (no AAD).
  const aesKey = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(atob(key), (c) => c.charCodeAt(0)),
    "AES-GCM",
    false,
    ["encrypt"],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv }, aesKey, new TextEncoder().encode("legacy-token")),
  );
  const legacy = `${btoa(String.fromCharCode(...iv))}.${btoa(String.fromCharCode(...ciphertext))}`;
  if (legacy.split(".").length !== 2) throw new Error("test fixture is not legacy-shaped");
  // With or without a context, a legacy row must keep decrypting.
  if (await decryptToken(legacy, key) !== "legacy-token") throw new Error("legacy decrypt failed");
  if (await decryptToken(legacy, key, context) !== "legacy-token") {
    throw new Error("legacy decrypt with context failed");
  }
});

Deno.test("decryptToken rejects unrecognized formats", async () => {
  for (const bad of ["", "a", "v2.a.b", "a.b.c", "v1.a"]) {
    let threw = false;
    try {
      await decryptToken(bad, key, context);
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`unrecognized format accepted: ${bad}`);
  }
});
