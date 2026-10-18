// Synthetic-certificate tests for app-attest.ts's certificate signature verification
// (audit F8: the digest must come from the certificate's signatureAlgorithm OID, not from the
// issuer's curve). The certificates here are hand-assembled minimal X.509 structures signed with
// throwaway keys; they exercise parseCertificate + verifyCertificateSignature only, NOT Apple's
// real chain. A real-device attestation fixture is still needed to prove the end-to-end path.
import {
  hashForSignatureAlgorithm,
  parseCertificate,
  verifyCertificateSignature,
} from "./app-attest.ts";

const OID_P256 = "1.2.840.10045.3.1.7";
const OID_P384 = "1.3.132.0.34";
const OID_ECDSA_SHA256 = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384 = "1.2.840.10045.4.3.3";
const OID_ECDSA_SHA512 = "1.2.840.10045.4.3.4";
const OID_RSA_SHA256 = "1.2.840.113549.1.1.11";

function tlv(tag: number, content: Uint8Array): Uint8Array {
  let header: number[];
  if (content.length < 0x80) header = [tag, content.length];
  else if (content.length < 0x100) header = [tag, 0x81, content.length];
  else header = [tag, 0x82, content.length >> 8, content.length & 0xff];
  return concat(new Uint8Array(header), content);
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function oid(dotted: string): Uint8Array {
  const arcs = dotted.split(".").map(Number);
  const bytes: number[] = [arcs[0] * 40 + arcs[1]];
  for (const arc of arcs.slice(2)) {
    const chunk: number[] = [];
    let value = arc;
    do {
      chunk.unshift(value & 0x7f);
      value = Math.floor(value / 128);
    } while (value > 0);
    for (let i = 0; i < chunk.length - 1; i++) chunk[i] |= 0x80;
    bytes.push(...chunk);
  }
  return tlv(0x06, new Uint8Array(bytes));
}

const text = (s: string) => new TextEncoder().encode(s);
const sequence = (...parts: Uint8Array[]) => tlv(0x30, concat(...parts));

function derInteger(bytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  let body = bytes.subarray(i);
  if (body[0] & 0x80) body = concat(new Uint8Array([0]), body);
  return tlv(0x02, body);
}

// Web Crypto returns ECDSA signatures as raw r||s; certificates carry DER ECDSA-Sig-Value.
function rawSignatureToDer(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  return sequence(derInteger(raw.subarray(0, half)), derInteger(raw.subarray(half)));
}

interface KeyAndCurve {
  keyPair: CryptoKeyPair;
  namedCurve: "P-256" | "P-384";
  curveOid: string;
}

async function generateKey(namedCurve: "P-256" | "P-384"): Promise<KeyAndCurve> {
  const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, [
    "sign",
    "verify",
  ]);
  return { keyPair, namedCurve, curveOid: namedCurve === "P-256" ? OID_P256 : OID_P384 };
}

async function spkiOf(key: CryptoKey): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.exportKey("spki", key));
}

// Builds a minimal v3 certificate whose subject key is `subject` and which is signed by
// `issuer` using `signHash`, declaring `declaredSigAlgOid` as its signatureAlgorithm.
async function buildCertificate(opts: {
  subject: KeyAndCurve;
  issuer: KeyAndCurve;
  signHash: "SHA-256" | "SHA-384" | "SHA-512";
  declaredSigAlgOid: string;
}): Promise<Uint8Array> {
  const sigAlg = sequence(oid(opts.declaredSigAlgOid));
  const tbs = sequence(
    tlv(0xa0, tlv(0x02, new Uint8Array([2]))), // [0] version v3
    tlv(0x02, new Uint8Array([1])), // serialNumber
    sigAlg, // signature (inner)
    sequence(), // issuer
    sequence(tlv(0x17, text("200101000000Z")), tlv(0x17, text("491231235959Z"))), // validity
    sequence(tlv(0x31, sequence(oid("2.5.4.3"), tlv(0x0c, text("Synthetic Subject"))))), // subject
    await spkiOf(opts.subject.keyPair.publicKey),
  );
  const rawSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: opts.signHash },
      opts.issuer.keyPair.privateKey,
      tbs as BufferSource,
    ),
  );
  const bitString = tlv(0x03, concat(new Uint8Array([0]), rawSignatureToDer(rawSignature)));
  return sequence(tbs, sigAlg, bitString);
}

async function verify(
  certificate: Uint8Array,
  issuer: KeyAndCurve,
): Promise<boolean> {
  return verifyCertificateSignature(
    parseCertificate(certificate),
    await spkiOf(issuer.keyPair.publicKey),
    issuer.curveOid,
  );
}

Deno.test("signature algorithm OIDs map to their digests", () => {
  const expected: Record<string, string> = {
    [OID_ECDSA_SHA256]: "SHA-256",
    [OID_ECDSA_SHA384]: "SHA-384",
    [OID_ECDSA_SHA512]: "SHA-512",
  };
  for (const [signatureOid, hash] of Object.entries(expected)) {
    if (hashForSignatureAlgorithm(signatureOid) !== hash) throw new Error(`wrong digest for ${signatureOid}`);
  }
  let threw = false;
  try {
    hashForSignatureAlgorithm(OID_RSA_SHA256);
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("non-ECDSA signature algorithm accepted");
});

Deno.test("a P-384 issuer's SHA-256 signature verifies by OID, not by curve", async () => {
  // The old code hashed with SHA-384 because the issuer is P-384, which would reject this
  // legitimately SHA-256-signed certificate.
  const issuer = await generateKey("P-384");
  const subject = await generateKey("P-384");
  const cert = await buildCertificate({
    subject,
    issuer,
    signHash: "SHA-256",
    declaredSigAlgOid: OID_ECDSA_SHA256,
  });
  if (!await verify(cert, issuer)) throw new Error("valid SHA-256-signed certificate rejected");
});

Deno.test("a P-384 issuer's SHA-384 signature verifies", async () => {
  const issuer = await generateKey("P-384");
  const subject = await generateKey("P-256");
  const cert = await buildCertificate({
    subject,
    issuer,
    signHash: "SHA-384",
    declaredSigAlgOid: OID_ECDSA_SHA384,
  });
  if (!await verify(cert, issuer)) throw new Error("valid SHA-384-signed certificate rejected");
});

Deno.test("a P-256 issuer's SHA-384 signature verifies by OID", async () => {
  const issuer = await generateKey("P-256");
  const subject = await generateKey("P-256");
  const cert = await buildCertificate({
    subject,
    issuer,
    signHash: "SHA-384",
    declaredSigAlgOid: OID_ECDSA_SHA384,
  });
  if (!await verify(cert, issuer)) throw new Error("valid P-256/SHA-384 certificate rejected");
});

Deno.test("a certificate that lies about its signature algorithm is rejected", async () => {
  const issuer = await generateKey("P-384");
  const subject = await generateKey("P-384");
  // Actually signed with SHA-256 but declares SHA-384: verifying with the declared digest fails.
  const cert = await buildCertificate({
    subject,
    issuer,
    signHash: "SHA-256",
    declaredSigAlgOid: OID_ECDSA_SHA384,
  });
  if (await verify(cert, issuer)) throw new Error("mismatched signature algorithm accepted");
});

Deno.test("a certificate signed by a different key is rejected", async () => {
  const issuer = await generateKey("P-384");
  const attacker = await generateKey("P-384");
  const subject = await generateKey("P-384");
  const cert = await buildCertificate({
    subject,
    issuer: attacker,
    signHash: "SHA-384",
    declaredSigAlgOid: OID_ECDSA_SHA384,
  });
  if (await verify(cert, issuer)) throw new Error("certificate signed by the wrong key accepted");
});

Deno.test("an unsupported signature algorithm OID is rejected", async () => {
  const issuer = await generateKey("P-384");
  const subject = await generateKey("P-384");
  const cert = await buildCertificate({
    subject,
    issuer,
    signHash: "SHA-256",
    declaredSigAlgOid: OID_RSA_SHA256,
  });
  let threw = false;
  try {
    await verify(cert, issuer);
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("unsupported signature algorithm accepted");
});
