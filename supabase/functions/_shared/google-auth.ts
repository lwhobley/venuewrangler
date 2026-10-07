// Google service-account OAuth2 (JWT bearer grant — RFC 7523), used to call the Play
// Integrity API without a user present. Implemented with Web Crypto (SubtleCrypto) since
// Deno's edge runtime has no Node crypto module and no `google-auth-library` equivalent that
// runs here.

interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function importPrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/// Exchanges a Google service account's credentials for a short-lived OAuth2 access token
/// scoped to [scope] (e.g. "https://www.googleapis.com/auth/playintegrity").
export async function getGoogleAccessToken(
  serviceAccountJson: string,
  scope: string,
): Promise<string> {
  const serviceAccount: ServiceAccount = JSON.parse(serviceAccountJson);
  const tokenUri = serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token";

  const header = { alg: "RS256", typ: "JWT" };
  const nowSeconds = Math.floor(Date.now() / 1000);
  const claims = {
    iss: serviceAccount.client_email,
    scope,
    aud: tokenUri,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  };

  const encoder = new TextEncoder();
  const headerB64 = base64UrlEncode(encoder.encode(JSON.stringify(header)));
  const claimsB64 = base64UrlEncode(encoder.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const privateKey = await importPrivateKey(serviceAccount.private_key);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    encoder.encode(signingInput),
  );
  const assertion = `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;

  const response = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`Google token exchange failed (${response.status}): ${await response.text()}`);
  }

  const data = await response.json();
  return data.access_token as string;
}
