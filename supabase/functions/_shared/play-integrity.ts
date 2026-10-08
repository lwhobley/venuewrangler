import { sha256Hex } from "./crypto.ts";

export async function matchesPlayIntegrityRequest(
  details: Record<string, unknown> | null | undefined,
  packageName: string,
  nonceBytes: Uint8Array<ArrayBuffer>,
  now = Date.now(),
): Promise<boolean> {
  if (!details || details.requestPackageName !== packageName) return false;
  const timestamp = Number(details.timestampMillis);
  const age = now - timestamp;
  if (!Number.isFinite(timestamp) || age < 0 || age > 5 * 60 * 1000) {
    return false;
  }
  const nonce = btoa(String.fromCharCode(...nonceBytes))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const nonceHash = await sha256Hex(nonceBytes);
  return details.nonce === nonce || details.requestHash === nonceHash;
}
