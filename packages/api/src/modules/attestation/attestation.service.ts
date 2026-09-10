import { Injectable, Logger } from '@nestjs/common';
import { createHash, randomBytes } from 'node:crypto';
import { verifyAssertion, verifyAttestation } from 'appattest-checker-node';
import {
  allowDevelopmentAttestation,
  AttestationError,
  attestationEnforced,
  requireAttestationConfig,
} from '../../common/app-attest';
import { PrismaService } from '../../prisma/prisma.service';

/** Challenges are short-lived; the client round-trips one immediately. */
const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const RETENTION_BATCH_SIZE = 1_000;

export type AssertionInput = {
  keyId: string;
  /** Base64 CBOR assertion produced by DCAppAttestService.generateAssertion. */
  assertion: string;
  challenge: string;
};

/** The library returns a result object rather than throwing. */
function failure(result: object): result is { verifyError: string; errorMessage?: string } {
  return 'verifyError' in result;
}

@Injectable()
export class AttestationService {
  private readonly logger = new Logger(AttestationService.name);

  constructor(private readonly prisma: PrismaService) {}

  private observeInvalid(reason: string): void {
    this.logger.warn(`attestation_observation status=invalid reason=${reason}`);
  }

  /**
   * Issue a single-use nonce. The client signs it alongside the request body,
   * which is what stops a captured assertion from being replayed later.
   */
  async issueChallenge(userId: string): Promise<{ challenge: string; expiresAt: number }> {
    const value = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + CHALLENGE_TTL_MS);
    await this.prisma.attestationChallenge.create({ data: { userId, value, expiresAt } });
    return { challenge: value, expiresAt: expiresAt.getTime() };
  }

  /**
   * Atomically consume a challenge. updateMany with `consumedAt: null` in the
   * filter makes this a compare-and-set: two requests racing the same challenge
   * produce exactly one winner, so a challenge is never usable twice.
   */
  private async consumeChallenge(userId: string, value: string): Promise<void> {
    const { count } = await this.prisma.attestationChallenge.updateMany({
      where: { value, userId, consumedAt: null, expiresAt: { gt: new Date() } },
      data: { consumedAt: new Date() },
    });
    if (count !== 1) {
      this.observeInvalid('challenge');
      throw new AttestationError('Attestation challenge is invalid, expired, or already used.');
    }
  }

  /**
   * Verify a fresh App Attest attestation and record the device key. Called
   * once per install, before the device can produce assertions.
   */
  async registerDevice(userId: string, input: { keyId: string; attestation: string; challenge: string }) {
    const { appId, developmentEnv } = requireAttestationConfig();
    await this.consumeChallenge(userId, input.challenge);

    const result = await verifyAttestation(
      { appId, developmentEnv },
      input.keyId,
      Buffer.from(input.challenge),
      Buffer.from(input.attestation, 'base64'),
    );

    if (failure(result)) {
      this.observeInvalid('registration');
      this.logger.warn(
        `App Attest attestation rejected for user ${userId}: ${result.verifyError} ${result.errorMessage ?? ''}`.trim(),
      );
      throw new AttestationError('Device attestation could not be verified.');
    }

    // upsert keyed on keyId so re-attesting the same device refreshes it rather
    // than colliding on the unique index. signCount resets to 0 because Apple's
    // counter restarts with a freshly attested key.
    const environment = developmentEnv ? 'development' : 'production';
    await this.prisma.deviceAttestation.upsert({
      where: { keyId: input.keyId },
      create: { userId, keyId: input.keyId, publicKey: result.publicKeyPem, environment, signCount: 0 },
      update: { userId, publicKey: result.publicKeyPem, environment, signCount: 0 },
    });
    return { registered: true as const };
  }

  /**
   * Verify that `payload` was signed by a previously attested device.
   *
   * Returns silently when attestation is not enforced and none was supplied, so
   * older app builds keep working during the staged rollout — but a supplied
   * assertion is always verified, and a bad one is always rejected.
   */
  async verifyRequest(userId: string, payload: unknown, input: AssertionInput | undefined): Promise<void> {
    if (!input) {
      if (attestationEnforced()) {
        this.observeInvalid('missing');
        throw new AttestationError('This app version cannot verify device integrity. Please update Venue Wrangler.');
      }
      this.logger.log('attestation_observation status=missing');
      return;
    }

    const { appId, developmentEnv } = requireAttestationConfig();
    await this.consumeChallenge(userId, input.challenge);

    const device = await this.prisma.deviceAttestation.findUnique({ where: { keyId: input.keyId } });
    if (!device || device.userId !== userId) {
      this.observeInvalid('device');
      throw new AttestationError('This device is not registered for attestation.');
    }
    // A key attested in Apple's development environment must never authorise a
    // production punch, even if the row somehow exists.
    if (device.environment !== (developmentEnv ? 'development' : 'production')) {
      this.observeInvalid('environment');
      throw new AttestationError('This device is not registered for attestation.');
    }

    // The hash must cover exactly what the server will act on, plus the
    // one-time challenge — otherwise a caller could sign a benign payload and
    // submit a different one.
    const clientDataHash = createHash('sha256').update(canonicalPayload(payload, input.challenge)).digest();

    const result = await verifyAssertion(
      clientDataHash,
      device.publicKey,
      appId,
      Buffer.from(input.assertion, 'base64'),
    );

    if (failure(result)) {
      this.observeInvalid('assertion');
      this.logger.warn(
        `App Attest assertion rejected for user ${userId}: ${result.verifyError} ${result.errorMessage ?? ''}`.trim(),
      );
      throw new AttestationError('Device integrity check failed for this request.');
    }

    // Apple's counter is monotonic; the library explicitly leaves this check to
    // the caller. Guarding the update on the previous value makes it a
    // compare-and-set, so a replayed assertion (equal counter) loses even when
    // two requests arrive concurrently.
    const { count } = await this.prisma.deviceAttestation.updateMany({
      where: { keyId: input.keyId, signCount: { lt: result.signCount } },
      data: { signCount: result.signCount, lastUsedAt: new Date() },
    });
    if (count !== 1) {
      this.observeInvalid('replay');
      this.logger.warn(`App Attest replay rejected for user ${userId}: signCount did not advance.`);
      throw new AttestationError('Device integrity check failed for this request.');
    }
    this.logger.log('attestation_observation status=valid');
  }

  /**
   * Scheduled retention job: purge expired or consumed challenges to prevent unbounded table growth.
   */
  async cleanupExpiredChallenges(): Promise<number> {
    const now = new Date();
    const where = {
      OR: [
        { expiresAt: { lt: now } },
        { consumedAt: { not: null } },
      ],
    };
    let total = 0;
    for (;;) {
      const batch = await this.prisma.attestationChallenge.findMany({
        where,
        orderBy: { id: 'asc' },
        take: RETENTION_BATCH_SIZE,
        select: { id: true },
      });
      if (batch.length === 0) break;
      const result = await this.prisma.attestationChallenge.deleteMany({
        where: { id: { in: batch.map(({ id }) => id) } },
      });
      // Progress guard: if a selected page deletes nothing, the next iteration
      // would re-select the same page forever. Matches the same guard in
      // audit.service.ts's retention loops.
      if (result.count === 0) break;
      total += result.count;
    }
    if (total > 0) this.logger.log(`Cleaned up ${total} expired/consumed attestation challenges.`);
    return total;
  }
}

/**
 * Stable string for signing. JSON.stringify preserves insertion order, which
 * would differ between client and server, so keys are sorted explicitly. The
 * iOS client must produce a byte-identical string.
 */
export function canonicalPayload(payload: unknown, challenge: string): string {
  return JSON.stringify({ challenge, payload: sortValue(payload) });
}

function sortValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
        .map(([key, entry]) => [key, sortValue(entry)]),
    );
  }
  return value;
}
