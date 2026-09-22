import { describe, expect, it, vi, beforeEach } from 'vitest';

const cleanupOldAuditLogs = vi.fn();
const cleanupExpiredRetainedTimeEntries = vi.fn();
const cleanupExpiredChallenges = vi.fn();
const closeApp = vi.fn();
const initSentry = vi.fn();
const captureException = vi.fn();
const flushSentry = vi.fn().mockResolvedValue(true);

vi.mock('@nestjs/core', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@nestjs/core')>();
  return {
    ...actual,
    NestFactory: {
      createApplicationContext: vi.fn(async () => ({
        get: (token: unknown) => {
          if (token === AuditServiceToken) return { cleanupOldAuditLogs, cleanupExpiredRetainedTimeEntries };
          if (token === AttestationServiceToken) return { cleanupExpiredChallenges };
          throw new Error(`Unexpected token in test double: ${String(token)}`);
        },
        close: closeApp,
      })),
    },
  };
});

vi.mock('./observability/sentry', () => ({ initSentry, captureException, flushSentry }));
// This unit test exercises orchestration, not the full module dependency graph.
// Loading production providers inside a timed test made cold CI imports race
// the following test's shared mocks after a timeout.
vi.mock('./retention.module', () => ({ RetentionModule: class RetentionModule {} }));

// Real classes, used only as map keys above — retention.ts imports the actual
// exports, so `app.get(AuditService)` in production resolves against these
// same class references.
import { AuditService as AuditServiceToken } from './modules/audit/audit.service';
import { AttestationService as AttestationServiceToken } from './modules/attestation/attestation.service';

describe('runRetention', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('initializes Sentry before creating the app context, so captureException is never silently inert', async () => {
    cleanupOldAuditLogs.mockResolvedValue(0);
    cleanupExpiredRetainedTimeEntries.mockResolvedValue(0);
    cleanupExpiredChallenges.mockResolvedValue(0);
    const { runRetention } = await import('./retention');

    await runRetention();

    expect(initSentry).toHaveBeenCalled();
  });

  it('runs all three cleanup jobs sequentially, in order, and closes the app context', async () => {
    const order: string[] = [];
    cleanupOldAuditLogs.mockImplementation(async () => { order.push('auditLogs'); return 3; });
    cleanupExpiredRetainedTimeEntries.mockImplementation(async () => { order.push('wageRecords'); return 5; });
    cleanupExpiredChallenges.mockImplementation(async () => { order.push('challenges'); return 7; });
    const { runRetention } = await import('./retention');

    await runRetention();

    expect(order).toEqual(['auditLogs', 'wageRecords', 'challenges']);
    expect(closeApp).toHaveBeenCalledTimes(1);
  });

  it('closes the app context even when a cleanup job throws', async () => {
    cleanupOldAuditLogs.mockResolvedValue(0);
    cleanupExpiredRetainedTimeEntries.mockRejectedValue(new Error('db unreachable'));
    cleanupExpiredChallenges.mockResolvedValue(0);
    const { runRetention } = await import('./retention');

    await expect(runRetention()).rejects.toThrow('db unreachable');

    expect(closeApp).toHaveBeenCalledTimes(1);
    // The job that runs after the failure must not have been reached.
    expect(cleanupExpiredChallenges).not.toHaveBeenCalled();
  });

  it('captures and flushes a fatal job error before marking the process failed', async () => {
    const originalExitCode = process.exitCode;
    const { reportRetentionFailure } = await import('./retention');
    const error = new Error('retention failed');

    try {
      await reportRetentionFailure(error);

      expect(captureException).toHaveBeenCalledWith(error, { job: 'retention' });
      expect(flushSentry).toHaveBeenCalledOnce();
      expect(captureException.mock.invocationCallOrder[0]).toBeLessThan(flushSentry.mock.invocationCallOrder[0]);
      expect(process.exitCode).toBe(1);
    } finally {
      process.exitCode = originalExitCode;
    }
  });
});
