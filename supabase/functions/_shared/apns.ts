// Apple Push Notification service (APNs) HTTP/2 provider API, token-based auth (ES256 JWT).
// See https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
//
// Deno's fetch negotiates HTTP/2 automatically over TLS when the server supports it (as
// api.push.apple.com does via ALPN), so a plain fetch() is sufficient — no separate HTTP/2
// client library is needed, unlike most APNs provider libraries written for runtimes without
// built-in HTTP/2 client support.

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const base64 = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// Module-scoped caches: Edge Function isolates are reused across invocations (see
// observability.ts's comment on the same pattern), so re-importing the key and re-signing a
// JWT on every single push would be wasted work — Apple also rate-limits token generation.
let cachedKey: { pem: string; key: CryptoKey } | null = null;
let cachedToken: { teamId: string; keyId: string; jwt: string; issuedAt: number } | null = null;
const TOKEN_TTL_MS = 50 * 60 * 1000; // Apple tokens are valid up to 1 hour; refresh before that.

async function getSigningKey(pem: string): Promise<CryptoKey> {
  if (cachedKey && cachedKey.pem === pem) return cachedKey.key;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  cachedKey = { pem, key };
  return key;
}

// Web Crypto's ECDSA signatures are already raw (r || s, 64 bytes for P-256) — exactly the
// format JWS ES256 expects — unlike the ASN.1 DER signatures this codebase's App Attest
// verification has to parse out of certificates elsewhere (see _shared/der.ts).
async function signApnsJwt(teamId: string, keyId: string, privateKeyPem: string): Promise<string> {
  if (
    cachedToken &&
    cachedToken.teamId === teamId &&
    cachedToken.keyId === keyId &&
    Date.now() - cachedToken.issuedAt < TOKEN_TTL_MS
  ) {
    return cachedToken.jwt;
  }

  const header = { alg: "ES256", kid: keyId };
  const claims = { iss: teamId, iat: Math.floor(Date.now() / 1000) };
  const headerB64 = base64UrlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const claimsB64 = base64UrlEncode(new TextEncoder().encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await getSigningKey(privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  const jwt = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
  cachedToken = { teamId, keyId, jwt, issuedAt: Date.now() };
  return jwt;
}

export interface ApnsSendResult {
  ok: boolean;
  status: number;
  // Apple's JSON `reason` field on failure, e.g. "BadDeviceToken", "Unregistered",
  // "DeviceTokenNotForTopic". See Apple's table of APNs response reasons.
  reason?: string;
}

export interface ApnsConfig {
  privateKeyPem: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  // Development-signed builds (Xcode debug runs, most non-TestFlight local builds) attest and
  // register against the sandbox APNs environment; TestFlight and App Store builds use
  // production. Getting this wrong for a given token doesn't crash anything — Apple just
  // returns "BadDeviceToken" — but it does mean the push silently never arrives.
  sandbox: boolean;
}

export function loadApnsConfigFromEnv(): ApnsConfig | null {
  const privateKeyPem = Deno.env.get("APNS_KEY");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID");
  if (!privateKeyPem || !keyId || !teamId || !bundleId) return null;
  return { privateKeyPem, keyId, teamId, bundleId, sandbox: Deno.env.get("APNS_SANDBOX") === "true" };
}

export async function sendApnsPush(
  config: ApnsConfig,
  params: { deviceToken: string; title: string; body: string; data?: Record<string, unknown> },
): Promise<ApnsSendResult> {
  const jwt = await signApnsJwt(config.teamId, config.keyId, config.privateKeyPem);
  const host = config.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";

  const res = await fetch(`https://${host}/3/device/${params.deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: params.title, body: params.body }, sound: "default" },
      ...(params.data ?? {}),
    }),
    signal: AbortSignal.timeout(5000),
  });

  if (res.ok) return { ok: true, status: res.status };
  const errBody = await res.json().catch(() => ({}));
  return { ok: false, status: res.status, reason: errBody?.reason };
}
