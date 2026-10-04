// Ported from packages/api/src/modules/documents/document-malware-scanner.service.ts. Fails
// closed exactly like legacy: if CLAMAV_HOST isn't configured, a document upload is refused
// outright (503) rather than silently skipping the scan.
//
// Uses Deno.connect (raw TCP) to speak clamd's own INSTREAM protocol directly — Supabase's
// Edge Runtime supports raw TCP sockets (it's the same mechanism official docs use for a
// direct, driver-less Postgres connection from a function), but this has NOT been exercised
// against a real clamd instance in this environment (none is reachable here). The protocol
// itself (zINSTREAM + 4-byte-BE-length-prefixed chunks + a zero-length terminator chunk) is
// clamd's standard wire format, unchanged from the Node implementation this was ported from.

const DEFAULT_CLAMAV_PORT = 3310;
const DEFAULT_CLAMAV_TIMEOUT_MS = 10_000;
const CLAMAV_CHUNK_BYTES = 64 * 1024;
const MAX_CLAMAV_RESPONSE_BYTES = 4096;

export class DocumentScanUnavailableError extends Error {}
export class DocumentScanRejectedError extends Error {}

export function assertCleanClamAvResponse(response: string): void {
  const normalized = response.replace(/\0/g, "").trim();
  if (/\bOK$/i.test(normalized)) return;
  if (/\bFOUND$/i.test(normalized)) {
    throw new DocumentScanRejectedError("Document was rejected by malware scanning.");
  }
  throw new DocumentScanUnavailableError("Document malware scanning did not return a valid result.");
}

function positiveInteger(raw: string | undefined, fallback: number): number {
  const value = Number.parseInt(raw ?? "", 10);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

async function scanClamAvStream(host: string, port: number, timeoutMs: number, data: Uint8Array): Promise<string> {
  const conn = await Promise.race([
    Deno.connect({ hostname: host, port }),
    new Promise<never>((_, reject) =>
      setTimeout(() => reject(new DocumentScanUnavailableError("Document malware scanning is temporarily unavailable.")), timeoutMs)
    ),
  ]);

  try {
    const writer = conn;
    const encoder = new TextEncoder();
    await writer.write(encoder.encode("zINSTREAM\0"));

    for (let offset = 0; offset < data.length; offset += CLAMAV_CHUNK_BYTES) {
      const chunk = data.subarray(offset, Math.min(offset + CLAMAV_CHUNK_BYTES, data.length));
      const length = new Uint8Array(4);
      new DataView(length.buffer).setUint32(0, chunk.length, false);
      await writer.write(length);
      await writer.write(chunk);
    }
    // Zero-length chunk terminates the stream, per clamd's INSTREAM protocol.
    await writer.write(new Uint8Array(4));

    const responseChunks: Uint8Array[] = [];
    let responseBytes = 0;
    const buf = new Uint8Array(4096);

    const readLoop = (async () => {
      while (true) {
        const n = await Promise.race([
          conn.read(buf),
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new DocumentScanUnavailableError("Document malware scanning timed out.")), timeoutMs)
          ),
        ]);
        if (n === null) break;
        responseBytes += n;
        if (responseBytes > MAX_CLAMAV_RESPONSE_BYTES) {
          throw new DocumentScanUnavailableError("Document malware scanning returned an unexpectedly large response.");
        }
        const slice = buf.subarray(0, n);
        responseChunks.push(slice.slice());
        if (slice.includes(0) || slice.includes(10)) break;
      }
    })();

    await readLoop;
    const total = responseChunks.reduce((acc, c) => acc + c.length, 0);
    const merged = new Uint8Array(total);
    let pos = 0;
    for (const c of responseChunks) {
      merged.set(c, pos);
      pos += c.length;
    }
    return new TextDecoder().decode(merged);
  } finally {
    try {
      conn.close();
    } catch {
      // already closed
    }
  }
}

/** Throws DocumentScanRejectedError if infected, DocumentScanUnavailableError if ClamAV can't be reached or isn't configured. */
export async function assertDocumentClean(data: Uint8Array): Promise<void> {
  const host = Deno.env.get("CLAMAV_HOST")?.trim();
  if (!host) {
    throw new DocumentScanUnavailableError("Document malware scanning is not configured.");
  }
  const port = positiveInteger(Deno.env.get("CLAMAV_PORT"), DEFAULT_CLAMAV_PORT);
  const timeoutMs = positiveInteger(Deno.env.get("CLAMAV_TIMEOUT_MS"), DEFAULT_CLAMAV_TIMEOUT_MS);
  const response = await scanClamAvStream(host, port, timeoutMs, data);
  assertCleanClamAvResponse(response);
}
