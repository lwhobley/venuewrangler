// AES-256-GCM encryption for OAuth tokens at rest (PAYROLL_TOKEN_ENCRYPTION_KEY, >=32 random
// bytes, base64-encoded — see supabase/.env.example) and HMAC-SHA256 signing for the OAuth
// `state` parameter carried through a provider's redirect, using Web Crypto (SubtleCrypto)
// since Deno's edge runtime has no Node `crypto` module.

function base64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function importAesKey(base64Key: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", base64ToBytes(base64Key), "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

async function importHmacKey(base64Key: string): Promise<CryptoKey> {
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
  const valid = await crypto.subtle.verify(
    "HMAC",
    key,
    base64ToBytes(signatureB64),
    new TextEncoder().encode(payloadB64),
  );
  if (!valid) return null;

  const payload = JSON.parse(atob(payloadB64)) as OAuthStatePayload;
  if (Date.now() - payload.issued_at > STATE_TTL_MS) return null;
  return payload;
}
