// Real cryptographic verification of an Apple App Attest attestation, following the 9-step
// algorithm Apple documents at
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
// — the same algorithm implemented by the MIT-licensed `node-app-attest` npm package, whose
// source was read directly to get the exact byte offsets and OIDs right (verified against the
// real Apple App Attestation Root CA certificate's own DER structure before trusting it — see
// the comments below for what was checked).
//
// Deno's edge runtime has no Node `crypto` module (no `X509Certificate`), so this uses a
// hand-rolled minimal DER parser (der.ts) and CBOR decoder (cbor.ts) plus Web Crypto
// (SubtleCrypto) instead of a third-party ASN.1/X.509 library — same approach already used in
// this codebase for RS256 JWT signing (google-auth.ts) and AES-GCM/HMAC (crypto.ts).

import { decodeCbor, type CborValue } from "./cbor.ts";
import { parseDerNode, parseDerChildren, derSlice, derFullSlice, decodeOid, derIntegerToUnsignedBytes } from "./der.ts";

// Apple's own published App Attest root CA certificate (not a secret — safe to embed). Verified
// by this project against the certificate's real DER structure: ECDSA P-384 self-signed root,
// subject CN "Apple App Attestation Root CA", signature algorithm ecdsa-with-SHA384
// (OID 1.2.840.10045.4.3.3).
const APPLE_APP_ATTESTATION_ROOT_CA_B64 =
  "MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD";

const NONCE_EXTENSION_OID = "1.2.840.113635.100.8.2";
const SUB_CA_COMMON_NAME = "Apple App Attestation CA 1";

const AAGUID_DEVELOPMENT = "appattestdevelop"; // ASCII, 16 bytes
const AAGUID_PRODUCTION = new Uint8Array([
  ...new TextEncoder().encode("appattest"),
  0, 0, 0, 0, 0, 0, 0,
]);

function base64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", data as BufferSource);
  return new Uint8Array(digest);
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

interface ParsedCertificate {
  raw: Uint8Array;
  tbsCertificateRaw: Uint8Array;
  signatureAlgorithmOid: string;
  signatureRaw: Uint8Array; // the BIT STRING content: a DER ECDSA-Sig-Value (r, s)
  subjectPublicKeyInfoRaw: Uint8Array; // full SPKI DER, for crypto.subtle.importKey("spki", ...)
  publicKeyPointRaw: Uint8Array; // just the EC point bytes inside the SPKI's BIT STRING
  curveOid: string;
  subjectCommonName: string | null;
  notBefore: Date;
  notAfter: Date;
  extensions: Map<string, Uint8Array>; // OID -> extnValue content bytes
}

const CURVE_OID_TO_WEBCRYPTO: Record<string, { namedCurve: string; hash: string; order: number }> = {
  "1.2.840.10045.3.1.7": { namedCurve: "P-256", hash: "SHA-256", order: 32 }, // prime256v1
  "1.3.132.0.34": { namedCurve: "P-384", hash: "SHA-384", order: 48 }, // secp384r1
  "1.3.132.0.35": { namedCurve: "P-521", hash: "SHA-512", order: 66 }, // secp521r1
};

function parseAsn1Time(bytes: Uint8Array, isGeneralized: boolean): Date {
  const str = new TextDecoder().decode(bytes);
  // UTCTime: YYMMDDHHMMSSZ (2-digit year, 50-99 -> 19xx, 00-49 -> 20xx, per X.509 convention).
  // GeneralizedTime: YYYYMMDDHHMMSSZ.
  const match = isGeneralized
    ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(str)
    : /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(str);
  if (!match) throw new Error(`app-attest: unparseable certificate time value "${str}"`);
  let year: number;
  if (isGeneralized) {
    year = Number(match[1]);
  } else {
    const yy = Number(match[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
  }
  const [, , month, day, hour, minute, second] = isGeneralized
    ? [null, null, match[2], match[3], match[4], match[5], match[6]]
    : [null, null, match[2], match[3], match[4], match[5], match[6]];
  return new Date(Date.UTC(year, Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second)));
}

function parseCertificate(raw: Uint8Array): ParsedCertificate {
  const certNode = parseDerNode(raw, 0);
  if (certNode.tagNumber !== 16 || !certNode.constructed) {
    throw new Error("app-attest: certificate is not a DER SEQUENCE");
  }
  const [tbsNode, sigAlgNode, sigValueNode] = parseDerChildren(raw, certNode.contentStart, certNode.contentEnd);
  if (!tbsNode || !sigAlgNode || !sigValueNode) {
    throw new Error("app-attest: certificate is missing tbsCertificate/signatureAlgorithm/signatureValue");
  }

  const sigAlgChildren = parseDerChildren(raw, sigAlgNode.contentStart, sigAlgNode.contentEnd);
  const signatureAlgorithmOid = decodeOid(derSlice(raw, sigAlgChildren[0]));

  // signatureValue is a BIT STRING: first content byte is the "unused bits" count (always 0
  // for a DER-encoded signature), the rest is the actual DER ECDSA-Sig-Value.
  const sigBitString = derSlice(raw, sigValueNode);
  const signatureRaw = sigBitString.subarray(1);

  const tbsChildren = parseDerChildren(raw, tbsNode.contentStart, tbsNode.contentEnd);
  // tbsCertificate ::= SEQUENCE { [0] version, serialNumber, signature, issuer, validity,
  //   subject, subjectPublicKeyInfo, [1] issuerUniqueID OPTIONAL, [2] subjectUniqueID OPTIONAL,
  //   [3] extensions OPTIONAL }
  // version is an explicit [0]-tagged field — always present on a v3 cert, which every
  // certificate in this chain is, so a fixed index into tbsChildren is safe here.
  const validityNode = tbsChildren[4];
  const subjectNode = tbsChildren[5];
  const spkiNode = tbsChildren[6];

  const [notBeforeNode, notAfterNode] = parseDerChildren(raw, validityNode.contentStart, validityNode.contentEnd);
  const notBefore = parseAsn1Time(derSlice(raw, notBeforeNode), notBeforeNode.tagNumber === 24);
  const notAfter = parseAsn1Time(derSlice(raw, notAfterNode), notAfterNode.tagNumber === 24);

  // subject ::= SEQUENCE OF RelativeDistinguishedName (a SET OF AttributeTypeAndValue each).
  // Find the commonName (OID 2.5.4.3) attribute's string value, if any.
  let subjectCommonName: string | null = null;
  for (const rdn of parseDerChildren(raw, subjectNode.contentStart, subjectNode.contentEnd)) {
    for (const atv of parseDerChildren(raw, rdn.contentStart, rdn.contentEnd)) {
      const [oidNode, valueNode] = parseDerChildren(raw, atv.contentStart, atv.contentEnd);
      if (decodeOid(derSlice(raw, oidNode)) === "2.5.4.3") {
        subjectCommonName = new TextDecoder().decode(derSlice(raw, valueNode));
      }
    }
  }

  const spkiChildren = parseDerChildren(raw, spkiNode.contentStart, spkiNode.contentEnd);
  const algIdNode = spkiChildren[0];
  const publicKeyBitStringNode = spkiChildren[1];
  const algIdChildren = parseDerChildren(raw, algIdNode.contentStart, algIdNode.contentEnd);
  const curveOid = algIdChildren[1] ? decodeOid(derSlice(raw, algIdChildren[1])) : "";
  const publicKeyBitString = derSlice(raw, publicKeyBitStringNode);
  const publicKeyPointRaw = publicKeyBitString.subarray(1); // drop the "unused bits" byte

  const extensions = new Map<string, Uint8Array>();
  const extTagNode = tbsChildren.find((n) => n.tagClass === 2 && n.tagNumber === 3);
  if (extTagNode) {
    const extSeqNode = parseDerNode(raw, extTagNode.contentStart);
    for (const ext of parseDerChildren(raw, extSeqNode.contentStart, extSeqNode.contentEnd)) {
      const extFields = parseDerChildren(raw, ext.contentStart, ext.contentEnd);
      const oid = decodeOid(derSlice(raw, extFields[0]));
      // extnValue is always the last field (critical BOOLEAN is optional in between).
      const extnValueNode = extFields[extFields.length - 1];
      extensions.set(oid, derSlice(raw, extnValueNode));
    }
  }

  return {
    raw,
    tbsCertificateRaw: derFullSlice(raw, tbsNode),
    signatureAlgorithmOid,
    signatureRaw,
    subjectPublicKeyInfoRaw: derFullSlice(raw, spkiNode),
    publicKeyPointRaw,
    curveOid,
    subjectCommonName,
    notBefore,
    notAfter,
    extensions,
  };
}

// Converts a DER ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) into the raw, fixed-length
// r||s format Web Crypto's ECDSA verify expects (IEEE P1363), padding each to the curve's order.
function derSignatureToRaw(derSig: Uint8Array, orderBytes: number): Uint8Array {
  const seqNode = parseDerNode(derSig, 0);
  const [rNode, sNode] = parseDerChildren(derSig, seqNode.contentStart, seqNode.contentEnd);
  const r = derIntegerToUnsignedBytes(derSlice(derSig, rNode));
  const s = derIntegerToUnsignedBytes(derSlice(derSig, sNode));

  const out = new Uint8Array(orderBytes * 2);
  out.set(r, orderBytes - r.length);
  out.set(s, orderBytes * 2 - s.length);
  return out;
}

async function verifyCertificateSignature(
  cert: ParsedCertificate,
  issuerPublicKeySpki: Uint8Array,
  issuerCurveOid: string,
): Promise<boolean> {
  const curveInfo = CURVE_OID_TO_WEBCRYPTO[issuerCurveOid];
  if (!curveInfo) {
    throw new Error(`app-attest: unsupported issuer curve OID ${issuerCurveOid}`);
  }

  const publicKey = await crypto.subtle.importKey(
    "spki",
    issuerPublicKeySpki as BufferSource,
    { name: "ECDSA", namedCurve: curveInfo.namedCurve },
    false,
    ["verify"],
  );

  const rawSignature = derSignatureToRaw(cert.signatureRaw, curveInfo.order);

  return crypto.subtle.verify(
    { name: "ECDSA", hash: curveInfo.hash },
    publicKey,
    rawSignature as BufferSource,
    cert.tbsCertificateRaw as BufferSource,
  );
}

export interface AppAttestVerificationResult {
  keyId: string;
  publicKeySpkiBase64: string;
  receiptBase64: string;
  environment: "production" | "development";
}

export interface VerifyAppAttestParams {
  /** The base64 or raw attestation object bytes the client sent. */
  attestationObject: Uint8Array;
  /** The server-issued challenge the client hashed into clientDataHash before attesting. */
  challenge: Uint8Array;
  /** The key identifier (base64 SHA-256 of the public key) the client's generateKey() returned. */
  keyId: string;
  bundleIdentifier: string;
  teamIdentifier: string;
  allowDevelopmentEnvironment: boolean;
}

/**
 * Verifies an Apple App Attest attestation per Apple's documented 9-step algorithm. Throws with
 * a descriptive message on any verification failure; returns the verified key material and
 * environment on success.
 */
export async function verifyAppAttest(params: VerifyAppAttestParams): Promise<AppAttestVerificationResult> {
  const { attestationObject, challenge, keyId, bundleIdentifier, teamIdentifier, allowDevelopmentEnvironment } =
    params;

  let decoded: CborValue;
  try {
    decoded = decodeCbor(attestationObject);
  } catch (err) {
    throw new Error(`app-attest: invalid CBOR attestation object: ${err instanceof Error ? err.message : err}`);
  }

  if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) {
    throw new Error("app-attest: attestation object is not a CBOR map");
  }
  const attestation = decoded as Record<string, CborValue>;

  if (attestation.fmt !== "apple-appattest") {
    throw new Error(`app-attest: unexpected fmt "${String(attestation.fmt)}", expected "apple-appattest"`);
  }

  const attStmt = attestation.attStmt as Record<string, CborValue> | undefined;
  const authData = attestation.authData as Uint8Array | undefined;
  if (!attStmt || !authData || !(authData instanceof Uint8Array)) {
    throw new Error("app-attest: attestation object is missing attStmt or authData");
  }

  const x5c = attStmt.x5c as CborValue[] | undefined;
  const receipt = attStmt.receipt as Uint8Array | undefined;
  if (!x5c || x5c.length !== 2 || !receipt || !(receipt instanceof Uint8Array)) {
    throw new Error("app-attest: attStmt.x5c must contain exactly 2 certificates, and a receipt");
  }
  if (!(x5c[0] instanceof Uint8Array) || !(x5c[1] instanceof Uint8Array)) {
    throw new Error("app-attest: attStmt.x5c entries must be byte strings");
  }

  // Step 1: parse both certificates, identify leaf (credCert) vs intermediate (sub CA) by
  // subject common name, and verify the chain up to Apple's hardcoded root.
  const certA = parseCertificate(x5c[0] as Uint8Array);
  const certB = parseCertificate(x5c[1] as Uint8Array);

  const subCaCert = certA.subjectCommonName === SUB_CA_COMMON_NAME ? certA : certB;
  const leafCert = subCaCert === certA ? certB : certA;
  if (subCaCert.subjectCommonName !== SUB_CA_COMMON_NAME) {
    throw new Error(`app-attest: no certificate with subject CN "${SUB_CA_COMMON_NAME}" found in x5c`);
  }

  const rootCert = parseCertificate(base64ToBytes(APPLE_APP_ATTESTATION_ROOT_CA_B64));
  const now = new Date();
  for (const [label, cert] of [["sub CA", subCaCert], ["leaf", leafCert]] as const) {
    if (now < cert.notBefore || now > cert.notAfter) {
      throw new Error(`app-attest: ${label} certificate is not within its validity period`);
    }
  }

  const subCaVerified = await verifyCertificateSignature(subCaCert, rootCert.subjectPublicKeyInfoRaw, rootCert.curveOid);
  if (!subCaVerified) {
    throw new Error("app-attest: sub CA certificate is not signed by Apple's App Attestation Root CA");
  }

  const leafVerified = await verifyCertificateSignature(leafCert, subCaCert.subjectPublicKeyInfoRaw, subCaCert.curveOid);
  if (!leafVerified) {
    throw new Error("app-attest: leaf (credCert) certificate is not signed by the Apple App Attestation sub CA");
  }

  // Step 2 & 3: nonce = SHA256(authData || SHA256(challenge)).
  const clientDataHash = await sha256(challenge);
  const nonce = await sha256(concatBytes(authData, clientDataHash));

  // Step 4: the nonce extension (OID 1.2.840.113635.100.8.2) on the leaf cert is a DER SEQUENCE
  // containing a single context-specific [1]-tagged element, which itself contains a single
  // OCTET STRING — that octet string's bytes must equal the nonce computed above.
  const nonceExtensionValue = leafCert.extensions.get(NONCE_EXTENSION_OID);
  if (!nonceExtensionValue) {
    throw new Error(`app-attest: leaf certificate is missing the nonce extension (OID ${NONCE_EXTENSION_OID})`);
  }
  const nonceSeqNode = parseDerNode(nonceExtensionValue, 0);
  const [nonceWrapperNode] = parseDerChildren(nonceExtensionValue, nonceSeqNode.contentStart, nonceSeqNode.contentEnd);
  const [nonceOctetStringNode] = parseDerChildren(
    nonceExtensionValue,
    nonceWrapperNode.contentStart,
    nonceWrapperNode.contentEnd,
  );
  const actualNonce = derSlice(nonceExtensionValue, nonceOctetStringNode);
  if (bytesToHex(actualNonce) !== bytesToHex(nonce)) {
    throw new Error("app-attest: nonce does not match (attestation was not generated for this challenge)");
  }

  // Step 5: SHA256(public key) must equal the client-supplied keyId.
  const publicKeyHash = await sha256(leafCert.publicKeyPointRaw);
  const publicKeyHashBase64 = bytesToBase64(publicKeyHash);
  if (publicKeyHashBase64 !== keyId) {
    throw new Error("app-attest: keyId does not match SHA256(public key) from the credential certificate");
  }

  // Step 6: authData's rpIdHash (first 32 bytes) must equal SHA256(teamId.bundleId).
  const appIdHash = await sha256(new TextEncoder().encode(`${teamIdentifier}.${bundleIdentifier}`));
  const rpIdHash = authData.subarray(0, 32);
  if (bytesToHex(rpIdHash) !== bytesToHex(appIdHash)) {
    throw new Error("app-attest: rpIdHash does not match this app's team + bundle identifier");
  }

  // Step 7: the counter (bytes 33-37; byte 32 is the authenticator-data flags byte) must be 0
  // on initial attestation — a nonzero counter here would mean a replayed/forged authenticator.
  const counterView = new DataView(authData.buffer, authData.byteOffset + 33, 4);
  if (counterView.getUint32(0, false) !== 0) {
    throw new Error("app-attest: authData counter must be 0 on initial attestation");
  }

  // Step 8: aaguid (bytes 37-53) identifies development vs production.
  const aaguid = authData.subarray(37, 53);
  const aaguidHex = bytesToHex(aaguid);
  const isDevelopment = aaguidHex === bytesToHex(new TextEncoder().encode(AAGUID_DEVELOPMENT));
  const isProduction = aaguidHex === bytesToHex(AAGUID_PRODUCTION);
  if (!isDevelopment && !isProduction) {
    throw new Error("app-attest: authData aaguid is neither the development nor production App Attest value");
  }
  if (isDevelopment && !allowDevelopmentEnvironment) {
    throw new Error("app-attest: development-environment attestations are not allowed by this server's configuration");
  }

  // Step 9: credentialId (bytes 55+, length-prefixed at 53-55) must equal the keyId too.
  const credentialIdLengthView = new DataView(authData.buffer, authData.byteOffset + 53, 2);
  const credentialIdLength = credentialIdLengthView.getUint16(0, false);
  const credentialId = authData.subarray(55, 55 + credentialIdLength);
  if (bytesToBase64(credentialId) !== keyId) {
    throw new Error("app-attest: authData credentialId does not match the supplied keyId");
  }

  return {
    keyId,
    publicKeySpkiBase64: bytesToBase64(leafCert.subjectPublicKeyInfoRaw),
    receiptBase64: bytesToBase64(receipt),
    environment: isProduction ? "production" : "development",
  };
}
