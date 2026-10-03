// Minimal CBOR (RFC 8949) decoder — just enough to parse an App Attest attestation object
// ({ fmt: tstr, attStmt: { x5c: [bstr, bstr], receipt: bstr }, authData: bstr }), without
// pulling in an external library. Deno's edge runtime has no Node modules available, and this
// project's standing rule (see der.ts, crypto.ts, google-auth.ts) is to hand-roll a narrowly
// scoped parser over an unverified third-party dependency for exactly this kind of thing.
//
// Supports definite-length encoding only for major types 0 (unsigned int), 2 (byte string),
// 3 (text string), 4 (array), and 5 (map) — everything Apple's attestation object actually
// uses. Anything else (floats, indefinite length, tags) throws rather than silently
// misinterpreting data it wasn't built to handle.

export type CborValue =
  | number
  | bigint
  | Uint8Array
  | string
  | CborValue[]
  | { [key: string]: CborValue };

interface DecodeResult {
  value: CborValue;
  offset: number;
}

function readLength(bytes: Uint8Array, offset: number, additionalInfo: number): { length: number; offset: number } {
  if (additionalInfo < 24) {
    return { length: additionalInfo, offset };
  }
  if (additionalInfo === 24) {
    return { length: bytes[offset], offset: offset + 1 };
  }
  if (additionalInfo === 25) {
    const view = new DataView(bytes.buffer, bytes.byteOffset + offset, 2);
    return { length: view.getUint16(0, false), offset: offset + 2 };
  }
  if (additionalInfo === 26) {
    const view = new DataView(bytes.buffer, bytes.byteOffset + offset, 4);
    return { length: view.getUint32(0, false), offset: offset + 4 };
  }
  if (additionalInfo === 27) {
    const view = new DataView(bytes.buffer, bytes.byteOffset + offset, 8);
    const length = view.getBigUint64(0, false);
    if (length > BigInt(Number.MAX_SAFE_INTEGER)) {
      throw new Error("cbor: length exceeds safe integer range");
    }
    return { length: Number(length), offset: offset + 8 };
  }
  throw new Error("cbor: indefinite-length encoding is not supported");
}

function decodeValue(bytes: Uint8Array, offset: number): DecodeResult {
  const initialByte = bytes[offset];
  const majorType = initialByte >> 5;
  const additionalInfo = initialByte & 0x1f;
  offset += 1;

  switch (majorType) {
    case 0: {
      // unsigned integer
      const { length, offset: next } = readLength(bytes, offset, additionalInfo);
      return { value: length, offset: next };
    }
    case 2: {
      // byte string
      const { length, offset: next } = readLength(bytes, offset, additionalInfo);
      return { value: bytes.subarray(next, next + length), offset: next + length };
    }
    case 3: {
      // text string
      const { length, offset: next } = readLength(bytes, offset, additionalInfo);
      const strBytes = bytes.subarray(next, next + length);
      return { value: new TextDecoder().decode(strBytes), offset: next + length };
    }
    case 4: {
      // array
      const { length, offset: next } = readLength(bytes, offset, additionalInfo);
      const arr: CborValue[] = [];
      let cursor = next;
      for (let i = 0; i < length; i++) {
        const result = decodeValue(bytes, cursor);
        arr.push(result.value);
        cursor = result.offset;
      }
      return { value: arr, offset: cursor };
    }
    case 5: {
      // map
      const { length, offset: next } = readLength(bytes, offset, additionalInfo);
      const obj: { [key: string]: CborValue } = {};
      let cursor = next;
      for (let i = 0; i < length; i++) {
        const keyResult = decodeValue(bytes, cursor);
        cursor = keyResult.offset;
        const valueResult = decodeValue(bytes, cursor);
        cursor = valueResult.offset;
        if (typeof keyResult.value !== "string") {
          throw new Error("cbor: only text-string map keys are supported");
        }
        obj[keyResult.value] = valueResult.value;
      }
      return { value: obj, offset: cursor };
    }
    default:
      throw new Error(`cbor: unsupported major type ${majorType}`);
  }
}

export function decodeCbor(bytes: Uint8Array): CborValue {
  const { value } = decodeValue(bytes, 0);
  return value;
}
