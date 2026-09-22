import { describe, expect, it, vi } from 'vitest';
import { PosController } from './pos.controller';
import { POS_PROVIDER_CAPABILITIES, POS_PROVIDERS } from './pos-provider-capabilities';

const scope = { venueId: 'venue-1', profileId: 'manager-1', fullName: 'Ada', role: 'manager', allAccess: false } as any;

describe('POS provider capabilities', () => {
  it('declares every provider and does not mark a vendor pull as implemented', () => {
    expect(POS_PROVIDER_CAPABILITIES.map((row) => row.provider).sort()).toEqual([...POS_PROVIDERS].sort());
    for (const row of POS_PROVIDER_CAPABILITIES) {
      expect(row.historicalSync).not.toBe('implemented');
      expect(row.realtime).toBe('unavailable');
      expect(row.oauth).not.toBe('implemented');
      expect(row.rateLimit).toContain('120 ingest requests');
      expect(row.regions.length).toBeGreaterThan(0);
    }
  });
});

describe('POS aggregator', () => {
  it('reports webhook feeds and provider totals from stored checks', async () => {
    const prisma = {
      posConnection: { findMany: vi.fn().mockResolvedValue([{ provider: 'square', status: 'connected', lastSyncAt: new Date('2026-09-22T12:00:00Z') }]) },
      posCheck: {
        count: vi.fn().mockResolvedValue(2),
        findMany: vi.fn().mockResolvedValue([]),
        aggregate: vi.fn().mockResolvedValue({ _sum: { totalCents: 4000, tipCents: 500, taxCents: 300 } }),
        groupBy: vi.fn().mockResolvedValue([
          { provider: 'square', _count: { _all: 2 }, _sum: { totalCents: 4000, tipCents: 500, taxCents: 300 } },
        ]),
      },
    };
    const controller = new PosController(prisma as never);
    const status = await controller.getAggregatorStatus(scope);
    expect(status.feedMode).toBe('webhook');
    expect(status.connectedProviders.find((row) => row.provider === 'square')?.capabilities).toMatchObject({
      oauth: 'provider_only',
      webhook: 'ingest_only',
      historicalSync: 'provider_only',
      realtime: 'unavailable',
    });
    expect(status.connectedProviders.find((row) => row.provider === 'toast')?.capabilities?.oauth).toBe('unavailable');
    expect(status.activeFeedsCount).toBe(1);
    const settlement = await controller.getAggregatorSettlement(scope);
    expect(settlement.providerBreakdown).toEqual([
      { provider: 'square', checkCount: 2, grossCents: 4000, tipsCents: 500, taxCents: 300 },
    ]);
    expect(settlement.tenderSplits).toEqual([]);
  });

  it('records an 86 list without calling a POS', async () => {
    const prisma = {
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-1' }) },
    };
    const controller = new PosController(prisma as never);
    const result = await controller.sync86Broadcast(scope, { itemNames: ['Gin'] });
    expect(result.deliveryMode).toBe('internal_audit_only');
    expect(result.targetEndpoints).toEqual([]);
    expect(prisma.auditLog.create).toHaveBeenCalled();
  });
});
