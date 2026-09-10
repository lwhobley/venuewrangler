import { afterEach, describe, expect, it, vi } from 'vitest';
import { ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { PosController } from './pos.controller';
import { hashWebhookSecret, secretsMatch } from '../../common/webhook-auth';

vi.mock('../../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));

import { assertWithinSharedRateLimit } from '../../common/rate-limit';

function makeController() {
  const prisma = {
    posConnection: {
      findFirst: vi.fn().mockResolvedValue(null),
      findMany: vi.fn().mockResolvedValue([]),
      update: vi.fn().mockResolvedValue({}),
      create: vi.fn(),
    },
    posCheck: {
      upsert: vi.fn().mockResolvedValue({}),
      findMany: vi.fn().mockResolvedValue([]),
      aggregate: vi.fn().mockResolvedValue({ _sum: { totalCents: 0, tipCents: 0 } }),
      count: vi.fn().mockResolvedValue(0),
      groupBy: vi.fn().mockResolvedValue([]),
    },
    posLaborPunch: {
      upsert: vi.fn().mockResolvedValue({}),
      groupBy: vi.fn().mockResolvedValue([]),
    },
    venue: { findUnique: vi.fn().mockResolvedValue({ timezone: 'America/New_York' }) },
    $queryRaw: vi.fn().mockResolvedValue([]),
    $executeRaw: vi.fn().mockResolvedValue(undefined),
    $transaction: vi.fn().mockImplementation((ops: any[]) => Promise.all(ops)),
  } as any;
  const controller = new PosController(prisma);
  return { controller, prisma };
}

const managerScope = { venueId: 'venue-1', profileId: 'manager-1', role: 'manager', allAccess: false } as any;
const staffScope = { venueId: 'venue-1', profileId: 'staff-1', role: 'staff', allAccess: false } as any;

function makeRequest(ip = '203.0.113.5') {
  return { ip } as any;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('PosController', () => {
  describe('ingest webhook', () => {
    it('verifies the webhook secret before touching the rate limiter', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue(null);

      await expect(controller.ingest(makeRequest(), 'venue-1', 'secret', { provider: 'toast' } as any))
        .rejects.toThrow(UnauthorizedException);

      // An unauthenticated spray of random venueIds must not churn buckets.
      expect(assertWithinSharedRateLimit).not.toHaveBeenCalled();
    });

    it('applies a per-venue, per-IP rate limit once the secret is verified', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: hashWebhookSecret('secret') });

      await controller.ingest(makeRequest(), 'venue-1', 'secret', { provider: 'toast' } as any);

      expect(assertWithinSharedRateLimit).toHaveBeenCalledWith(
        prisma,
        'pos-ingest:venue-1:203.0.113.5',
        120,
        60_000,
        'Too many webhook requests.',
      );
    });

    it('rejects when no matching POS connection exists', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue(null);

      await expect(controller.ingest(makeRequest(), 'venue-1', 'any-secret', { provider: 'toast' } as any))
        .rejects.toThrow('Invalid webhook secret');
    });

    it('rejects a webhook secret that does not match the stored hash', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: hashWebhookSecret('correct-secret') });

      await expect(controller.ingest(makeRequest(), 'venue-1', 'wrong-secret', { provider: 'toast' } as any))
        .rejects.toThrow('Invalid webhook secret');
    });

    it('refuses an update for a paused connection even with a valid secret', async () => {
      // Regression: pausing changed what the integrations screen said but did
      // not stop the next valid delivery, so a venue that had switched the feed
      // off kept receiving POS data. The secret stays valid because pausing is
      // reversible and must not force a rotation.
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', status: 'paused', webhookSecret: hashWebhookSecret('secret') });

      await expect(controller.ingest(makeRequest(), 'venue-1', 'secret', { provider: 'toast' } as any))
        .rejects.toThrow('This POS connection is paused. Resume it in Venue Wrangler to accept updates.');
      expect(prisma.posCheck.upsert).not.toHaveBeenCalled();
    });

    it('rejects when the connection has no webhook secret configured', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: null });

      await expect(controller.ingest(makeRequest(), 'venue-1', 'any-secret', { provider: 'toast' } as any))
        .rejects.toThrow('Invalid webhook secret');
    });

    // $executeRaw is invoked as `this.prisma.$executeRaw(Prisma.sql\`...\`)`
    // — a single argument that is a Sql object with .strings/.values, not a
    // tagged-template call. Pull the interpolated values back out to assert
    // on them without hardcoding the exact SQL text.
    function sqlValuesOf(call: any): any[] {
      return call[0].values;
    }

    it('upserts checks and labor punches, then records lastSyncAt', async () => {
      const { controller, prisma } = makeController();
      const secret = 'correct-secret';
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: hashWebhookSecret(secret) });

      const result = await controller.ingest(makeRequest(), 'venue-1', secret, {
        provider: 'toast',
        checks: [{
          externalCheckId: 'chk-1', openedAt: Date.now(), subtotalCents: 1000, totalCents: 1100, tipCents: 100,
        }],
        laborPunches: [{
          externalEmployeeId: 'emp-1', employeeName: 'Alex', clockInAt: Date.now(), businessDate: '2026-07-15',
        }],
      } as any);

      expect(prisma.$executeRaw).toHaveBeenCalledTimes(1);
      expect(sqlValuesOf(prisma.$executeRaw.mock.calls[0])).toEqual(
        expect.arrayContaining(['venue-1', 'chk-1']),
      );
      expect(prisma.posLaborPunch.upsert).toHaveBeenCalledWith(expect.objectContaining({
        where: {
          venueId_provider_externalEmployeeId_businessDate: {
            venueId: 'venue-1', provider: 'toast', externalEmployeeId: 'emp-1', businessDate: '2026-07-15',
          },
        },
      }));
      expect(prisma.posConnection.update).toHaveBeenCalledWith({
        where: { id: 'conn-1' },
        data: { lastSyncAt: expect.any(Date) },
      });
      expect(result).toEqual({ ok: true, checksUpserted: 1, laborUpserted: 1 });
    });

    it('locks the core sale amounts once closed, in the same statement that still allows a tip/status correction', async () => {
      // Real Postgres enforcement of the paid/void guard is covered by
      // pos-check-immutability.integration.spec.ts — a mocked $executeRaw
      // can't execute the CASE logic. This only proves the query construction
      // and parameter passing are correct: every check goes through the same
      // single atomic call, with no separate pre-check step to race against.
      const { controller, prisma } = makeController();
      const secret = 'correct-secret';
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: hashWebhookSecret(secret) });

      const result = await controller.ingest(makeRequest(), 'venue-1', secret, {
        provider: 'toast',
        checks: [
          { externalCheckId: 'chk-closed', openedAt: Date.now(), subtotalCents: 999, totalCents: 999, tipCents: 0, status: 'paid' },
          { externalCheckId: 'chk-open', openedAt: Date.now(), subtotalCents: 500, totalCents: 550, tipCents: 50 },
        ],
      } as any);

      expect(prisma.posCheck.findMany).not.toHaveBeenCalled();
      expect(prisma.$executeRaw).toHaveBeenCalledTimes(2);
      const sqlText = String(prisma.$executeRaw.mock.calls[0][0].strings.join(''));
      expect(sqlText).toContain('ON CONFLICT');
      expect(sqlText).toContain('IN (\'paid\', \'void\')');
      expect(result.checksUpserted).toBe(2);
    });

    it('chunks large ingest batches into multiple transactions', async () => {
      const { controller, prisma } = makeController();
      const secret = 'correct-secret';
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: hashWebhookSecret(secret) });
      const checks = Array.from({ length: 250 }, (_, i) => ({
        externalCheckId: `chk-${i}`, openedAt: Date.now(), subtotalCents: 100, totalCents: 100, tipCents: 0,
      }));

      await controller.ingest(makeRequest(), 'venue-1', secret, { provider: 'toast', checks } as any);

      // 250 checks at INGEST_CHUNK_SIZE=100 -> 3 chunked transactions
      expect(prisma.$transaction).toHaveBeenCalledTimes(3);
    });
  });

  describe('manager-only guard', () => {
    it('rejects staff from the overview endpoint', async () => {
      const { controller } = makeController();
      await expect(controller.getPosOverview(staffScope)).rejects.toThrow(ForbiddenException);
    });

    it('rejects an uninitialized profile from connections upsert', async () => {
      const { controller } = makeController();
      await expect(controller.upsertPosConnection(undefined as any, { provider: 'toast', status: 'connected' }))
        .rejects.toThrow(ForbiddenException);
    });
  });

  describe('getPosOverview', () => {
    it('aggregates today totals and open checks scoped to the venue', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findMany.mockResolvedValue([
        { id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: null, status: 'connected', lastSyncAt: new Date('2026-07-15T10:00:00Z'), createdAt: new Date(), updatedAt: new Date() },
      ]);
      prisma.posCheck.aggregate.mockResolvedValue({ _sum: { totalCents: 5000, tipCents: 750 } });
      prisma.posCheck.count.mockResolvedValue(3);

      const result = await controller.getPosOverview(managerScope);

      expect(result.todaySalesCents).toBe(5000);
      expect(result.todayTipsCents).toBe(750);
      expect(result.openChecks).toBe(3);
      expect(result.lastSyncAt).toBe(new Date('2026-07-15T10:00:00Z').getTime());
      expect(prisma.posCheck.aggregate).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ venueId: 'venue-1', status: { not: 'void' } }),
      }));
    });
  });

  describe('upsertPosConnection', () => {
    it('looks up an existing provider connection regardless of location changes', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: 'old-location',
        status: 'connected', webhookSecret: hashWebhookSecret('already-set'), lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });
      prisma.posConnection.update.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: 'new-location',
        status: 'connected', lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });

      await controller.upsertPosConnection(managerScope, {
        provider: 'toast', status: 'connected', externalLocationId: 'new-location',
      });

      expect(prisma.posConnection.findFirst).toHaveBeenCalledWith({
        where: { venueId: 'venue-1', provider: 'toast' },
      });
      expect(prisma.posConnection.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: 'conn-1' },
        data: expect.objectContaining({ externalLocationId: 'new-location' }),
      }));
    });

    it('creates a new connection with a freshly generated webhook secret', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue(null);
      prisma.posConnection.create.mockResolvedValue({
        id: 'conn-new', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'connected', lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });

      const result = await controller.upsertPosConnection(managerScope, { provider: 'toast', status: 'connected' });

      expect(prisma.posConnection.create).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({ venueId: 'venue-1', webhookSecret: expect.stringMatching(/^sha256:/) }),
      }));
      expect(result.webhookSecret).toEqual(expect.any(String));
    });

    it('updates the winning connection when a concurrent create returns P2002', async () => {
      const { controller, prisma } = makeController();
      const winner = {
        id: 'conn-winner', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'connected', webhookSecret: hashWebhookSecret('winner-secret'), lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      };
      prisma.posConnection.findFirst.mockResolvedValueOnce(null).mockResolvedValueOnce(winner);
      prisma.posConnection.create.mockRejectedValue({ code: 'P2002' });
      prisma.posConnection.update.mockResolvedValue({ ...winner, status: 'paused' });

      const result = await controller.upsertPosConnection(managerScope, { provider: 'toast', status: 'paused' });

      expect(prisma.posConnection.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: 'conn-winner' },
        data: expect.not.objectContaining({ webhookSecret: expect.anything() }),
      }));
      expect(result.webhookSecret).toBeNull();
    });

    it('rotates the secret only when the existing connection has none', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'paused', webhookSecret: hashWebhookSecret('already-set'), lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });
      prisma.posConnection.update.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'connected', lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });

      const result = await controller.upsertPosConnection(managerScope, { provider: 'toast', status: 'connected' });

      expect(prisma.posConnection.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: 'conn-1' },
        data: expect.not.objectContaining({ webhookSecret: expect.anything() }),
      }));
      expect(result.webhookSecret).toBeNull();
    });

    it('issues a new secret when reconnecting an existing connection that had none', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'error', webhookSecret: null, lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });
      prisma.posConnection.update.mockResolvedValue({
        id: 'conn-1', venueId: 'venue-1', provider: 'toast', externalLocationId: null,
        status: 'connected', lastSyncAt: null, createdAt: new Date(), updatedAt: new Date(),
      });

      const result = await controller.upsertPosConnection(managerScope, { provider: 'toast', status: 'connected' });

      expect(prisma.posConnection.update).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({ webhookSecret: expect.stringMatching(/^sha256:/) }),
      }));
      expect(result.webhookSecret).toEqual(expect.any(String));
    });
  });

  describe('rotatePosConnectionSecret', () => {
    it('rotates a venue-scoped connection and returns the plaintext once', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue({ id: 'conn-1' });

      const result = await controller.rotatePosConnectionSecret(managerScope, 'conn-1');

      expect(prisma.posConnection.findFirst).toHaveBeenCalledWith({
        where: { id: 'conn-1', venueId: 'venue-1' },
        select: { id: true },
      });
      const update = prisma.posConnection.update.mock.calls[0][0];
      expect(update.where).toEqual({ id: 'conn-1' });
      expect(update.data.webhookSecret).toMatch(/^sha256:/);
      expect(secretsMatch(result.webhookSecret, update.data.webhookSecret)).toBe(true);
      expect(secretsMatch('old-secret', update.data.webhookSecret)).toBe(false);
    });

    it('does not reveal whether another venue owns a connection', async () => {
      const { controller, prisma } = makeController();
      prisma.posConnection.findFirst.mockResolvedValue(null);

      await expect(controller.rotatePosConnectionSecret(managerScope, 'foreign-connection'))
        .rejects.toThrow('POS connection not found');
      expect(prisma.posConnection.update).not.toHaveBeenCalled();
    });
  });

  describe('getLaborSummary', () => {
    it('sums declared and reported tips across employees', async () => {
      const { controller, prisma } = makeController();
      prisma.posLaborPunch.groupBy.mockResolvedValue([
        {
          externalEmployeeId: 'emp-1', employeeName: 'Alex', jobTitle: 'Server',
          _sum: { regularMinutes: 480, overtimeMinutes: 0, totalPayCents: 12000, tipsCents: 3000, declaredTipsCents: 500 },
        },
      ]);

      const result = await controller.getLaborSummary(managerScope, {});

      expect(result.byEmployee[0]).toEqual(expect.objectContaining({ employeeName: 'Alex', tipsCents: 3500, payCents: 12000 }));
      expect(result.totalTipsCents).toBe(3500);
    });
  });
});
