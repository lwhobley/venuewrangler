// Minimal DER (ASN.1 Distinguished Encoding Rules) decoder — just enough to parse an X.509
// certificate's structure (TBSCertificate, SubjectPublicKeyInfo, Extensions, signature) without
// pulling in an external ASN.1 library. Deno's edge runtime has no Node `crypto` module (no
// `X509Certificate`), same constraint already documented in crypto.ts and google-auth.ts, so
// this hand-rolled parser plus Web Crypto (SubtleCrypto) does the job instead.
//
// DER is a TLV (tag-length-value) encoding. This handles definite-length encoding only, which
// is all X.509 certificates ever use.

export interface DerNode {
  tagClass: number; // 0 = universal, 1 = application, 2 = context-specific, 3 = private
  constructed: boolean;
  tagNumber: number;
  // Byte range of this node's *contents* (i.e. the V in TLV), within the original buffer.
  contentStart: number;
  contentEnd: number;
  // Byte range of the whole node (tag + length + contents), within the original buffer.
  start: number;
  end: number;
}

export function parseDerNode(bytes: Uint8Array, offset: number): DerNode {
  const start = offset;
  const first = bytes[offset];
  const tagClass = (first >> 6) & 0x03;
  const constructed = (first & 0x20) !== 0;
  let tagNumber = first & 0x1f;
  offset += 1;

  if (tagNumber === 0x1f) {
    // High-tag-number form (not used anywhere in an X.509 cert's structure we need, but handle
    // it so an unexpected cert doesn't just silently misparse).
    tagNumber = 0;
    let byte: number;
    do {
      byte = bytes[offset];
      tagNumber = (tagNumber << 7) | (byte & 0x7f);
      offset += 1;
    } while (byte & 0x80);
  }

  const lengthByte = bytes[offset];
  offset += 1;
  let length: number;
  if ((lengthByte & 0x80) === 0) {
    length = lengthByte;
  } else {
    const numLengthBytes = lengthByte & 0x7f;
    if (numLengthBytes === 0) {
      throw new Error("der: indefinite-length encoding is not supported");
    }
    length = 0;
    for (let i = 0; i < numLengthBytes; i++) {
      length = (length << 8) | bytes[offset + i];
    }
    offset += numLengthBytes;
  }

  const contentStart = offset;
  const contentEnd = offset + length;
  return { tagClass, constructed, tagNumber, contentStart, contentEnd, start, end: contentEnd };
}

// Parses every top-level TLV within [start, end) — used to walk a SEQUENCE's/SET's children.
export function parseDerChildren(bytes: Uint8Array, start: number, end: number): DerNode[] {
  const nodes: DerNode[] = [];
  let offset = start;
  while (offset < end) {
    const node = parseDerNode(bytes, offset);
    nodes.push(node);
    offset = node.end;
  }
  return nodes;
}

export function derSlice(bytes: Uint8Array, node: DerNode): Uint8Array {
  return bytes.subarray(node.contentStart, node.contentEnd);
}

export function derFullSlice(bytes: Uint8Array, node: DerNode): Uint8Array {
  return bytes.subarray(node.start, node.end);
}

// Decodes an OBJECT IDENTIFIER's content bytes into its dotted string form, e.g. "1.2.840.10045.2.1".
export function decodeOid(contentBytes: Uint8Array): string {
  const arcs: number[] = [];
  const first = contentBytes[0];
  arcs.push(Math.floor(first / 40), first % 40);

  let value = 0;
  for (let i = 1; i < contentBytes.length; i++) {
    const byte = contentBytes[i];
    value = value * 128 + (byte & 0x7f);
    if ((byte & 0x80) === 0) {
      arcs.push(value);
      value = 0;
    }
  }
  return arcs.join(".");
}

// Decodes an INTEGER's content bytes (big-endian, signed per DER) into an unsigned big-endian
// byte array with any leading 0x00 sign-padding byte stripped — what ECDSA-Sig-Value's r/s
// fields actually need downstream.
export function derIntegerToUnsignedBytes(contentBytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < contentBytes.length - 1 && contentBytes[i] === 0x00) i++;
  return contentBytes.subarray(i);
}

export function derUtf8OrPrintableString(bytes: Uint8Array, node: DerNode): string {
  return new TextDecoder().decode(derSlice(bytes, node));
}
