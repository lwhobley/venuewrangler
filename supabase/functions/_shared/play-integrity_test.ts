import { sha256Hex } from "./crypto.ts";
import { matchesPlayIntegrityRequest } from "./play-integrity.ts";

Deno.test("Play Integrity verdict must match package, challenge, and time", async () => {
  const challenge = new Uint8Array(32);
  const now = 1_000_000;
  const details = {
    requestPackageName: "com.venuewrangler.app",
    requestHash: await sha256Hex(challenge),
    timestampMillis: String(now - 1000),
  };
  if (
    !await matchesPlayIntegrityRequest(
      details,
      "com.venuewrangler.app",
      challenge,
      now,
    )
  ) {
    throw new Error("valid request details rejected");
  }
  if (
    await matchesPlayIntegrityRequest(
      { ...details, requestPackageName: "other" },
      "com.venuewrangler.app",
      challenge,
      now,
    )
  ) {
    throw new Error("wrong package accepted");
  }
  if (
    await matchesPlayIntegrityRequest(
      { ...details, requestHash: "wrong" },
      "com.venuewrangler.app",
      challenge,
      now,
    )
  ) {
    throw new Error("wrong challenge accepted");
  }
  if (
    await matchesPlayIntegrityRequest(
      { ...details, timestampMillis: "1" },
      "com.venuewrangler.app",
      challenge,
      now,
    )
  ) {
    throw new Error("stale token accepted");
  }
});
