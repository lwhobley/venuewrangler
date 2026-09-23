import { describe, expect, it, vi } from 'vitest';
import { BarInventoryReportsService } from './bar-inventory-reports.service';

function makeItem(overrides: Record<string, any> = {}) {
  return {
    id: 'item-1', venueId: 'venue-1', name: 'House Vodka', unit: 'bottle',
    onHand: 1, parLevel: 4, unitCostCents: 1000, supplier: 'Acme', sku: null,
    ...overrides,
  };
}

function makeService(items: any[], consumptions: Array<{ itemId: string; quantity: number; reversedAt: Date | null }>) {
  const prisma = {
    barInventoryItem: { findMany: vi.fn().mockResolvedValue(items) },
    posInventoryConsumption: {
      findMany: vi.fn().mockImplementation(async () => consumptions.filter((row) => row.reversedAt === null)),
    },
  } as any;
  return { service: new BarInventoryReportsService(prisma), prisma };
}

function velocityFor(po: any, itemId: string) {
  for (const group of po.groups ?? []) {
    const line = (group.lines ?? []).find((row: any) => row._id === itemId);
    if (line) return line.dailyVelocity;
  }
  return undefined;
}

describe('BarInventoryReportsService purchase order velocity', () => {
  it('attributes recorded recipe consumption to its inventory item', async () => {
    const { service } = makeService(
      [makeItem({ id: 'gin', name: 'Gin' }), makeItem({ id: 'ginger', name: 'Ginger Beer' })],
      [{ itemId: 'ginger', quantity: 30, reversedAt: null }],
    );
    const po = await service.purchaseOrder('venue-1');
    expect(velocityFor(po, 'ginger')).toBe(1);
    expect(velocityFor(po, 'gin')).toBe(0);
  });

  it('excludes voided POS consumption from predicted demand', async () => {
    const { service, prisma } = makeService(
      [makeItem()],
      [{ itemId: 'item-1', quantity: 30, reversedAt: new Date() }],
    );
    const po = await service.purchaseOrder('venue-1');
    expect(velocityFor(po, 'item-1')).toBe(0);
    expect(prisma.posInventoryConsumption.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: expect.objectContaining({ venueId: 'venue-1', reversedAt: null }) }),
    );
  });

  it('reads the full stock and consumption window without a row cap', async () => {
    const { service, prisma } = makeService([makeItem()], []);
    await service.purchaseOrder('venue-1');
    expect(prisma.barInventoryItem.findMany).toHaveBeenCalledWith(expect.not.objectContaining({ take: expect.anything() }));
    expect(prisma.posInventoryConsumption.findMany).toHaveBeenCalledWith(expect.not.objectContaining({ take: expect.anything() }));
  });
});
