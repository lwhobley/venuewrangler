import { describe, expect, it, vi } from 'vitest';
import { BarInventoryReportsService } from './bar-inventory-reports.service';

function makeItem(overrides: Record<string, any> = {}) {
  return {
    id: 'item-1',
    venueId: 'venue-1',
    name: 'House Vodka',
    unit: 'bottle',
    onHand: 10,
    parLevel: 4,
    unitCostCents: 1000,
    supplier: 'Acme',
    sku: null,
    ...overrides,
  };
}

function makeService(items: any[], soldNames: Array<{ name: string; quantity: number }>) {
  const prisma = {
    barInventoryItem: { findMany: vi.fn().mockResolvedValue(items) },
    posCheck: { findMany: vi.fn().mockResolvedValue([{ menuItems: JSON.stringify(soldNames) }]) },
  } as any;
  return { service: new BarInventoryReportsService(prisma), prisma };
}

/** Daily velocity for one item, from the purchase-order line the report builds. */
function velocityFor(po: any, itemId: string) {
  for (const group of po.groups ?? []) {
    const line = (group.lines ?? []).find((l: any) => l._id === itemId);
    if (line) return line.dailyVelocity;
  }
  return undefined;
}

describe('BarInventoryReportsService purchaseOrder velocity', () => {
  it('credits a sale to exactly one inventory item, not every substring match', async () => {
    // "Gin" must not collect the sales of "Ginger Beer".
    const { service } = makeService(
      [makeItem({ id: 'gin', name: 'Gin', onHand: 1 }), makeItem({ id: 'ginger', name: 'Ginger Beer', onHand: 1 })],
      [{ name: 'Ginger Beer', quantity: 30 }],
    );

    const po = await service.purchaseOrder('venue-1');

    expect(velocityFor(po, 'ginger')).toBe(1);
    expect(velocityFor(po, 'gin')).toBe(0);
  });

  it('matches a name whose edges are punctuation', async () => {
    // \b only asserts a boundary beside a word character, so a leading '#' or a
    // trailing ')' made these items score zero velocity forever.
    const { service } = makeService(
      [makeItem({ id: 'nine', name: '#9 Gin', onHand: 1 }), makeItem({ id: 'nonino', name: 'Amaro (Nonino)', onHand: 1 })],
      [{ name: 'two of #9 Gin', quantity: 30 }, { name: 'Amaro (Nonino) neat', quantity: 60 }],
    );

    const po = await service.purchaseOrder('venue-1');

    expect(velocityFor(po, 'nine')).toBe(1);
    expect(velocityFor(po, 'nonino')).toBe(2);
  });

  it('prefers the most specific item when several names match', async () => {
    const { service } = makeService(
      [makeItem({ id: 'gin', name: 'Gin', onHand: 1 }), makeItem({ id: 'fizz', name: 'Gin Fizz', onHand: 1 })],
      [{ name: 'Gin Fizz', quantity: 30 }],
    );

    const po = await service.purchaseOrder('venue-1');

    expect(velocityFor(po, 'fizz')).toBe(1);
    expect(velocityFor(po, 'gin')).toBe(0);
  });

  it('reads the whole item list and check window, uncapped', async () => {
    const { service, prisma } = makeService([makeItem()], []);

    await service.purchaseOrder('venue-1');

    expect(prisma.barInventoryItem.findMany).toHaveBeenCalledWith(
      expect.not.objectContaining({ take: expect.anything() }),
    );
    expect(prisma.posCheck.findMany).toHaveBeenCalledWith(
      expect.not.objectContaining({ take: expect.anything() }),
    );
  });
});
