// Pure verification helpers for attested time punches (see time-clock-punch/index.ts and
// supabase/migrations/20261017130000_attested_punches.sql).
//
// A punch is attested when the device proves, for THIS exact request, that the app on a
// genuine device produced it:
//   iOS      App Attest assertion over SHA-256(payload_json): signature verified with the public
//            key stored when the key was attested, rpIdHash must match team.bundle, and the
//            assertion counter must strictly increase (replay protection).
//   Android  Play Integrity token whose requestHash equals hex SHA-256(payload_json), with a
//            recognised app and a device that meets device integrity.
// The payload itself carries a single-use server nonce and a timestamp, so neither a captured
// payload nor a captured assertion can be replayed.
import { decodeCbor, type CborValue } from "./cbor.ts";
import { derIntegerToUnsignedBytes, derSlice, parseDerChildren, parseDerNode } from "./der.ts";
import { sha256Hex } from "./crypto.ts";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_CLOCK_SKEW_MS = 2 * 60 * 1000;

export interface PunchPayload {
  v: 1;
  kind: "in" | "out";
  venue_id: string;
  lat: number;
  lng: number;
  accuracy_m: number;
  mocked: boolean;
  nonce: string;
  ts: number;
}

export class PunchPayloadError extends Error {}

/** Parses and validates the client-built payload string. Throws PunchPayloadError. */
export function parsePunchPayload(payloadJson: unknown, now = Date.now()): PunchPayload {
  if (typeof payloadJson !== "string" || payloadJson.length === 0 || payloadJson.length > 2048) {
    throw new PunchPayloadError("payload_json_invalid");
  }
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(payloadJson);
  } catch {
    throw new PunchPayloadError("payload_json_invalid");
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new PunchPayloadError("payload_json_invalid");
  }
  const { v, kind, venue_id, lat, lng, accuracy_m, mocked, nonce, ts } = raw;
  if (v !== 1) throw new PunchPayloadError("payload_version_unsupported");
  if (kind !== "in" && kind !== "out") throw new PunchPayloadError("payload_kind_invalid");
  if (typeof venue_id !== "string" || !UUID_PATTERN.test(venue_id)) {
    throw new PunchPayloadError("payload_venue_invalid");
  }
  if (typeof lat !== "number" || !Number.isFinite(lat) || lat < -90 || lat > 90 ||
      typeof lng !== "number" || !Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new PunchPayloadError("payload_location_invalid");
  }
  if (typeof accuracy_m !== "number" || !Number.isFinite(accuracy_m) || accuracy_m < 0 || accuracy_m > 10_000) {
    throw new PunchPayloadError("payload_accuracy_invalid");
  }
  if (typeof mocked !== "boolean") throw new PunchPayloadError("payload_mocked_invalid");
  if (typeof nonce !== "string" || !NONCE_PATTERN.test(nonce)) {
    throw new PunchPayloadError("payload_nonce_invalid");
  }
  if (typeof ts !== "number" || !Number.isFinite(ts) || Math.abs(now - ts) > MAX_CLOCK_SKEW_MS) {
    throw new PunchPayloadError("payload_timestamp_out_of_range");
  }
  return { v: 1, kind, venue_id, lat, lng, accuracy_m, mocked, nonce, ts };
}

export async function sha256Bytes(bytes: Uint8Array): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
}

export function utf8(text: string): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(text);
}

export function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function derToRawP256(der: Uint8Array): Uint8Array {
  const seq = parseDerNode(der, 0);
  const [rNode, sNode] = parseDerChildren(der, seq.contentStart, seq.contentEnd);
  const r = derIntegerToUnsignedBytes(derSlice(der, rNode));
  const s = derIntegerToUnsignedBytes(derSlice(der, sNode));
  if (r.length > 32 || s.length > 32) throw new Error("assertion: oversized signature integer");
  const out = new Uint8Array(64);
  out.set(r, 32 - r.length);
  out.set(s, 64 - s.length);
  return out;
}

export interface VerifyAssertionParams {
  /** CBOR assertion object ({ signature, authenticatorData }) the app produced. */
  assertion: Uint8Array;
  /** SHA-256 of the exact payload_json string (what the app passed as clientDataHash). */
  clientDataHash: Uint8Array;
  /** DER SubjectPublicKeyInfo stored when this key was attested. */
  publicKeySpki: Uint8Array;
  /** Highest counter already accepted for this key. */
  storedCounter: number;
  /** SHA-256 of "<teamId>.<bundleId>". */
  expectedRpIdHash: Uint8Array;
}

/** Verifies an App Attest assertion per Apple's documented steps. Throws on any failure. */
export async function verifyAppAttestAssertion(params: VerifyAssertionParams): Promise<{ counter: number }> {
  const decoded: CborValue = decodeCbor(params.assertion);
  if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded) || decoded instanceof Uint8Array) {
    throw new Error("assertion: not a CBOR map");
  }
  const map = decoded as Record<string, CborValue>;
  const signature = map.signature;
  const authData = map.authenticatorData;
  if (!(signature instanceof Uint8Array) || !(authData instanceof Uint8Array)) {
    throw new Error("assertion: missing signature or authenticatorData");
  }
  if (authData.length < 37) throw new Error("assertion: authenticatorData too short");

  const rpIdHash = authData.subarray(0, 32);
  if (rpIdHash.length !== params.expectedRpIdHash.length ||
      !rpIdHash.every((byte, i) => byte === params.expectedRpIdHash[i])) {
    throw new Error("assertion: rpIdHash mismatch");
  }

  const counter = new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0, false);
  if (counter <= params.storedCounter) throw new Error("assertion: counter did not increase");

  // nonce = SHA256(authData || clientDataHash); the signature is ECDSA-SHA256 over that nonce.
  const nonce = await sha256Bytes(concat(authData, params.clientDataHash));
  const publicKey = await crypto.subtle.importKey(
    "spki",
    params.publicKeySpki as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    derToRawP256(signature) as BufferSource,
    nonce as BufferSource,
  );
  if (!valid) throw new Error("assertion: signature verification failed");
  return { counter };
}

export interface PlayIntegrityDecoded {
  tokenPayloadExternal?: {
    requestDetails?: Record<string, unknown>;
    appIntegrity?: { appRecognitionVerdict?: string };
    deviceIntegrity?: { deviceRecognitionVerdict?: string[] };
  };
}

/**
 * Decides whether a decoded Play Integrity response vouches for this punch. `payloadHashHex` is
 * lowercase hex SHA-256 of payload_json, which the app supplied as the request's requestHash.
 */
export function evaluatePlayIntegrityForPunch(
  decoded: PlayIntegrityDecoded,
  packageName: string,
  payloadHashHex: string,
  now = Date.now(),
): { ok: boolean; reason: string } {
  const payload = decoded.tokenPayloadExternal;
  const details = payload?.requestDetails;
  if (!details || details.requestPackageName !== packageName) return { ok: false, reason: "package_mismatch" };
  if (details.requestHash !== payloadHashHex) return { ok: false, reason: "request_hash_mismatch" };
  const timestamp = Number(details.timestampMillis);
  const age = now - timestamp;
  if (!Number.isFinite(timestamp) || age < 0 || age > 5 * 60 * 1000) return { ok: false, reason: "token_stale" };
  if (payload?.appIntegrity?.appRecognitionVerdict !== "PLAY_RECOGNIZED") return { ok: false, reason: "app_not_recognized" };
  if (!(payload?.deviceIntegrity?.deviceRecognitionVerdict ?? []).includes("MEETS_DEVICE_INTEGRITY")) {
    return { ok: false, reason: "device_not_trusted" };
  }
  return { ok: true, reason: "verified" };
}

export async function payloadHashHex(payloadJson: string): Promise<string> {
  return await sha256Hex(utf8(payloadJson));
}
