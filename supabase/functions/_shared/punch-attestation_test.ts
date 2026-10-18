import {
  evaluatePlayIntegrityForPunch,
  parsePunchPayload,
  PunchPayloadError,
  sha256Bytes,
  utf8,
  verifyAppAttestAssertion,
} from "./punch-attestation.ts";

// Local assertions: the edge-function tests deliberately avoid remote (jsr/deno.land) imports.
function assert(condition: unknown, message = "assertion failed"): void {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertThrows(fn: () => unknown, errorClass: new (...args: never[]) => Error): void {
  try {
    fn();
  } catch (error) {
    if (error instanceof errorClass) return;
    throw new Error(`threw the wrong error type: ${error}`);
  }
  throw new Error("expected the function to throw");
}

async function assertRejects(
  fn: () => Promise<unknown>,
  errorClass: new (...args: never[]) => Error = Error,
  messageIncludes = "",
): Promise<void> {
  try {
    await fn();
  } catch (error) {
    if (!(error instanceof errorClass)) throw new Error(`rejected with the wrong error type: ${error}`);
    if (messageIncludes && !error.message.includes(messageIncludes)) {
      throw new Error(`error message ${JSON.stringify(error.message)} lacks ${JSON.stringify(messageIncludes)}`);
    }
    return;
  }
  throw new Error("expected the promise to reject");
}

const NOW = 1_800_000_000_000;
const NONCE = "A".repeat(43);

function payload(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    v: 1,
    kind: "in",
    venue_id: "d3000000-0000-0000-0000-0000000000a1",
    lat: 29.7604,
    lng: -95.3698,
    accuracy_m: 12,
    mocked: false,
    nonce: NONCE,
    ts: NOW,
    ...overrides,
  });
}

Deno.test("parsePunchPayload accepts a well-formed payload", () => {
  const parsed = parsePunchPayload(payload(), NOW);
  assertEquals(parsed.kind, "in");
  assertEquals(parsed.accuracy_m, 12);
});

Deno.test("parsePunchPayload rejects malformed or out-of-range payloads", () => {
  for (
    const bad of [
      payload({ v: 2 }),
      payload({ kind: "sideways" }),
      payload({ venue_id: "not-a-uuid" }),
      payload({ lat: 91 }),
      payload({ lng: "x" }),
      payload({ accuracy_m: -1 }),
      payload({ mocked: "no" }),
      payload({ nonce: "short" }),
      payload({ ts: NOW - 10 * 60 * 1000 }),
      payload({ ts: NOW + 10 * 60 * 1000 }),
      "[]",
      "not json",
      "",
    ]
  ) {
    assertThrows(() => parsePunchPayload(bad, NOW), PunchPayloadError);
  }
  assertThrows(() => parsePunchPayload(undefined, NOW), PunchPayloadError);
});

// ---- App Attest assertion fixtures built with a throwaway P-256 key ------------------------

function derInt(bytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  let body = bytes.subarray(i);
  if (body[0] & 0x80) body = Uint8Array.from([0, ...body]);
  return Uint8Array.from([0x02, body.length, ...body]);
}

function rawToDer(raw: Uint8Array): Uint8Array {
  const r = derInt(raw.subarray(0, 32));
  const s = derInt(raw.subarray(32));
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s]);
}

function cborBytes(bytes: Uint8Array): Uint8Array {
  if (bytes.length < 24) return Uint8Array.from([0x40 + bytes.length, ...bytes]);
  if (bytes.length < 256) return Uint8Array.from([0x58, bytes.length, ...bytes]);
  return Uint8Array.from([0x59, bytes.length >> 8, bytes.length & 0xff, ...bytes]);
}

function cborAssertion(signature: Uint8Array, authData: Uint8Array): Uint8Array {
  const text = (s: string) => Uint8Array.from([0x60 + s.length, ...new TextEncoder().encode(s)]);
  return Uint8Array.from([
    0xa2,
    ...text("signature"),
    ...cborBytes(signature),
    ...text("authenticatorData"),
    ...cborBytes(authData),
  ]);
}

async function fixture(counter: number, rpId = "TEAMID.com.example.app") {
  const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", keyPair.publicKey));
  const rpIdHash = await sha256Bytes(utf8(rpId));
  const authData = new Uint8Array(37);
  authData.set(rpIdHash, 0);
  new DataView(authData.buffer).setUint32(33, counter, false);
  const clientDataHash = await sha256Bytes(utf8(payload()));
  const authAndClient = new Uint8Array(authData.length + clientDataHash.length);
  authAndClient.set(authData, 0);
  authAndClient.set(clientDataHash, authData.length);
  const nonce = await sha256Bytes(authAndClient);
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keyPair.privateKey, nonce as BufferSource),
  );
  return {
    spki,
    clientDataHash,
    rpIdHash,
    authData,
    assertion: cborAssertion(rawToDer(rawSignature), authData),
  };
}

Deno.test("verifyAppAttestAssertion accepts a valid assertion and reports the counter", async () => {
  const f = await fixture(7);
  const result = await verifyAppAttestAssertion({
    assertion: f.assertion,
    clientDataHash: f.clientDataHash,
    publicKeySpki: f.spki,
    storedCounter: 6,
    expectedRpIdHash: f.rpIdHash,
  });
  assertEquals(result.counter, 7);
});

Deno.test("verifyAppAttestAssertion rejects a replayed or lower counter", async () => {
  const f = await fixture(7);
  for (const stored of [7, 8]) {
    await assertRejects(
      () =>
        verifyAppAttestAssertion({
          assertion: f.assertion,
          clientDataHash: f.clientDataHash,
          publicKeySpki: f.spki,
          storedCounter: stored,
          expectedRpIdHash: f.rpIdHash,
        }),
      Error,
      "counter",
    );
  }
});

Deno.test("verifyAppAttestAssertion rejects a different payload, key or app", async () => {
  const f = await fixture(3);
  const otherHash = await sha256Bytes(utf8(payload({ lat: 30 })));
  await assertRejects(
    () =>
      verifyAppAttestAssertion({
        assertion: f.assertion,
        clientDataHash: otherHash,
        publicKeySpki: f.spki,
        storedCounter: 0,
        expectedRpIdHash: f.rpIdHash,
      }),
    Error,
    "signature",
  );

  const other = await fixture(3);
  await assertRejects(
    () =>
      verifyAppAttestAssertion({
        assertion: f.assertion,
        clientDataHash: f.clientDataHash,
        publicKeySpki: other.spki,
        storedCounter: 0,
        expectedRpIdHash: f.rpIdHash,
      }),
    Error,
    "signature",
  );

  const wrongApp = await sha256Bytes(utf8("OTHER.com.evil.app"));
  await assertRejects(
    () =>
      verifyAppAttestAssertion({
        assertion: f.assertion,
        clientDataHash: f.clientDataHash,
        publicKeySpki: f.spki,
        storedCounter: 0,
        expectedRpIdHash: wrongApp,
      }),
    Error,
    "rpIdHash",
  );
});

Deno.test("verifyAppAttestAssertion rejects garbage", async () => {
  const f = await fixture(1);
  await assertRejects(() =>
    verifyAppAttestAssertion({
      assertion: Uint8Array.from([1, 2, 3]),
      clientDataHash: f.clientDataHash,
      publicKeySpki: f.spki,
      storedCounter: 0,
      expectedRpIdHash: f.rpIdHash,
    })
  );
});

// ---- Play Integrity ------------------------------------------------------------------------

function integrity(overrides: Record<string, unknown> = {}) {
  return {
    tokenPayloadExternal: {
      requestDetails: {
        requestPackageName: "com.venuewrangler.app",
        requestHash: "abc123",
        timestampMillis: String(NOW - 1000),
        ...overrides,
      },
      appIntegrity: { appRecognitionVerdict: "PLAY_RECOGNIZED" },
      deviceIntegrity: { deviceRecognitionVerdict: ["MEETS_DEVICE_INTEGRITY"] },
    },
  };
}

Deno.test("evaluatePlayIntegrityForPunch accepts a matching, fresh, trusted token", () => {
  assertEquals(evaluatePlayIntegrityForPunch(integrity(), "com.venuewrangler.app", "abc123", NOW).ok, true);
});

Deno.test("evaluatePlayIntegrityForPunch rejects each way a token can be wrong", () => {
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ requestPackageName: "com.evil" }, "package_mismatch"],
    [{ requestHash: "different" }, "request_hash_mismatch"],
    [{ timestampMillis: String(NOW - 10 * 60 * 1000) }, "token_stale"],
    [{ timestampMillis: String(NOW + 60_000) }, "token_stale"],
  ];
  for (const [override, reason] of cases) {
    const result = evaluatePlayIntegrityForPunch(integrity(override), "com.venuewrangler.app", "abc123", NOW);
    assertEquals(result.ok, false);
    assertEquals(result.reason, reason);
  }
  const untrusted = integrity();
  untrusted.tokenPayloadExternal.deviceIntegrity.deviceRecognitionVerdict = [];
  assertEquals(
    evaluatePlayIntegrityForPunch(untrusted, "com.venuewrangler.app", "abc123", NOW).reason,
    "device_not_trusted",
  );
  const unrecognized = integrity();
  unrecognized.tokenPayloadExternal.appIntegrity.appRecognitionVerdict = "UNRECOGNIZED_VERSION";
  assertEquals(
    evaluatePlayIntegrityForPunch(unrecognized, "com.venuewrangler.app", "abc123", NOW).reason,
    "app_not_recognized",
  );
  assert(!evaluatePlayIntegrityForPunch({}, "com.venuewrangler.app", "abc123", NOW).ok);
});
