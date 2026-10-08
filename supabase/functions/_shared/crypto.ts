// AES-256-GCM encryption for OAuth tokens at rest (PAYROLL_TOKEN_ENCRYPTION_KEY, >=32 random
// bytes, base64-encoded — see supabase/.env.example) and HMAC-SHA256 signing for the OAuth
// `state` parameter carried through a provider's redirect, using Web Crypto (SubtleCrypto)
// since Deno's edge runtime has no Node `crypto` module.

// Uint8Array<ArrayBuffer>, not the default Uint8Array<ArrayBufferLike>: Web Crypto's
// BufferSource rejects the wider type (it admits SharedArrayBuffer) under current TypeScript.
function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

// Used to look up an attestation_challenges row by its nonce without storing the nonce itself.
export async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function importAesKey(base64Key: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", base64ToBytes(base64Key), "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

function importHmacKey(base64Key: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    base64ToBytes(base64Key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

// Output: base64(iv) + "." + base64(ciphertext). A fresh random IV every call, per AES-GCM's
// requirement that an (key, iv) pair never repeat.
export async function encryptToken(plaintext: string, base64Key: string): Promise<string> {
  const key = await importAesKey(base64Key);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plaintext),
  );
  return `${bytesToBase64(iv)}.${bytesToBase64(new Uint8Array(ciphertext))}`;
}

export async function decryptToken(encoded: string, base64Key: string): Promise<string> {
  const [ivB64, ciphertextB64] = encoded.split(".");
  const key = await importAesKey(base64Key);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64ToBytes(ivB64) },
    key,
    base64ToBytes(ciphertextB64),
  );
  return new TextDecoder().decode(plaintext);
}

export interface OAuthStatePayload {
  venue_id: string;
  user_id: string;
  issued_at: number;
}

const STATE_TTL_MS = 10 * 60 * 1000; // 10 minutes — long enough for a provider's consent screen.

// Signed, not encrypted: venue_id/user_id aren't secret, but the signature stops a forged
// state value from redirecting a token exchange onto a venue the requester was never checked
// against in the first place.
export async function signOAuthState(
  payload: Omit<OAuthStatePayload, "issued_at">,
  base64Key: string,
): Promise<string> {
  const fullPayload: OAuthStatePayload = { ...payload, issued_at: Date.now() };
  const payloadB64 = btoa(JSON.stringify(fullPayload));
  const key = await importHmacKey(base64Key);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payloadB64));
  return `${payloadB64}.${bytesToBase64(new Uint8Array(signature))}`;
}

export async function verifyOAuthState(
  token: string,
  base64Key: string,
): Promise<OAuthStatePayload | null> {
  const [payloadB64, signatureB64] = token.split(".");
  if (!payloadB64 || !signatureB64) return null;

  const key = await importHmacKey(base64Key);
  try {
    const valid = await crypto.subtle.verify(
      "HMAC",
      key,
      base64ToBytes(signatureB64),
      new TextEncoder().encode(payloadB64),
    );
    if (!valid) return null;

    const payload = JSON.parse(atob(payloadB64)) as OAuthStatePayload;
    if (!payload || typeof payload.issued_at !== "number" ||
      payload.issued_at > Date.now() ||
      Date.now() - payload.issued_at > STATE_TTL_MS ||
      typeof payload.venue_id !== "string" ||
      typeof payload.user_id !== "string") return null;
    return payload;
  } catch {
    return null;
  }
}

export interface AttestationChallengePayload {
  user_id: string;
  device_id: string;
  nonce_b64: string;
  issued_at: number;
}

const ATTESTATION_CHALLENGE_TTL_MS = 5 * 60 * 1000; // 5 minutes — long enough for Secure
// Enclave key generation + attestKey(), short enough to keep the replay window this signed,
// stateless token can't fully close (no server-side single-use tracking exists — see
// device-attestation/index.ts's header comment) acceptably small for an observe-mode feature.

// Same signed-not-encrypted pattern as signOAuthState: binds a fresh random nonce to the exact
// user and device that requested it, so an attestation generated for one user/device's
// challenge can't be replayed against another's.
export interface SignedAttestationChallenge {
  token: string;
  nonceBytes: Uint8Array<ArrayBuffer>;
}

// Returns the nonce bytes alongside the signed token so the caller can record a server-side,
// single-use row for it (see attestation_challenges table) without needing to re-decode the
// token or duplicate the random-generation logic.
export async function signAttestationChallenge(
  userId: string,
  deviceId: string,
  base64Key: string,
): Promise<SignedAttestationChallenge> {
  const nonceBytes = crypto.getRandomValues(new Uint8Array(32));
  const payload: AttestationChallengePayload = {
    user_id: userId,
    device_id: deviceId,
    nonce_b64: bytesToBase64(nonceBytes),
    issued_at: Date.now(),
  };
  const payloadB64 = btoa(JSON.stringify(payload));
  const key = await importHmacKey(base64Key);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payloadB64));
  return { token: `${payloadB64}.${bytesToBase64(new Uint8Array(signature))}`, nonceBytes };
}

export async function verifyAttestationChallenge(
  token: string,
  userId: string,
  deviceId: string,
  base64Key: string,
): Promise<Uint8Array<ArrayBuffer> | null> {
  const [payloadB64, signatureB64] = token.split(".");
  if (!payloadB64 || !signatureB64) return null;

  const key = await importHmacKey(base64Key);
  try {
    const valid = await crypto.subtle.verify(
      "HMAC",
      key,
      base64ToBytes(signatureB64),
      new TextEncoder().encode(payloadB64),
    );
    if (!valid) return null;

    const payload = JSON.parse(atob(payloadB64)) as AttestationChallengePayload;
    if (!payload || typeof payload.issued_at !== "number" ||
      payload.issued_at > Date.now() ||
      Date.now() - payload.issued_at > ATTESTATION_CHALLENGE_TTL_MS ||
      payload.user_id !== userId || payload.device_id !== deviceId ||
      typeof payload.nonce_b64 !== "string") return null;
    const nonce = base64ToBytes(payload.nonce_b64);
    return nonce.length === 32 ? nonce : null;
  } catch {
    return null;
  }
}
