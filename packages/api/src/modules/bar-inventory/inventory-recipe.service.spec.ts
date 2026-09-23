import { describe, expect, it, vi } from 'vitest';
import { InventoryRecipeService } from './inventory-recipe.service';

const paidCheck = {
  venueId: 'venue-1', provider: 'toast', externalCheckId: 'check-1', status: 'paid',
  openedAt: new Date('2026-01-01T12:00:00Z'), closedAt: new Date('2026-01-01T13:00:00Z'),
  menuItems: [{ name: 'House Martini', quantity: 2 }],
};

function fixture(recipeUpdatedAt: Date, priorRows: any[] = []) {
  const recipe = {
    normalizedName: 'house martini', updatedAt: recipeUpdatedAt,
    ingredients: [{ itemId: 'vodka', quantity: 30, unit: 'ml', item: { baseUnit: 'ml', baseQuantity: 750 } }],
  };
  const prisma = {
    posInventoryConsumption: {
      findMany: vi.fn().mockResolvedValue(priorRows),
      create: vi.fn().mockResolvedValue({}),
      update: vi.fn().mockResolvedValue({}),
    },
    inventoryRecipe: {
      findMany: vi.fn().mockImplementation(async ({ where }: any) => recipeUpdatedAt <= where.updatedAt.lte ? [recipe] : []),
    },
  } as any;
  const movements = {
    record: vi.fn().mockImplementation(async ({ quantity }: { quantity: number }) => ({
      movement: { previousOnHand: 10, nextOnHand: 10 + quantity },
    })),
  } as any;
  return { service: new InventoryRecipeService(prisma, movements), prisma, movements };
}

describe('InventoryRecipeService sale cutoff', () => {
  it('does not deduct an old paid check when its recipe was added later', async () => {
    const { service, prisma, movements } = fixture(new Date('2026-01-02T00:00:00Z'));
    await service.processPosCheck(paidCheck);
    expect(prisma.inventoryRecipe.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: expect.objectContaining({ updatedAt: { lte: paidCheck.closedAt } }) }),
    );
    expect(movements.record).not.toHaveBeenCalled();
  });

  it('deducts an eligible sale in stock units once', async () => {
    const { service, prisma, movements } = fixture(new Date('2025-12-31T00:00:00Z'));
    await service.processPosCheck(paidCheck);
    expect(movements.record).toHaveBeenCalledWith(expect.objectContaining({
      itemId: 'vodka', movementType: 'transfer', quantity: -0.08,
    }));
    expect(prisma.posInventoryConsumption.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ itemId: 'vodka', quantity: 0.08, appliedQuantity: expect.any(Number) }),
    });
    expect(prisma.posInventoryConsumption.create.mock.calls[0][0].data.appliedQuantity).toBeCloseTo(0.08);
  });

  it('reinstates the recorded quantity after a void, even when the recipe changed', async () => {
    const prior = { id: 'consumption-1', itemId: 'vodka', quantity: 0.2, appliedQuantity: 0.2, cycle: 1, reversedAt: new Date() };
    const { service, prisma, movements } = fixture(new Date('2026-01-02T00:00:00Z'), [prior]);
    await service.processPosCheck(paidCheck);
    expect(movements.record).toHaveBeenCalledWith(expect.objectContaining({
      itemId: 'vodka', quantity: -0.2, movementType: 'transfer',
    }));
    expect(prisma.posInventoryConsumption.update).toHaveBeenCalledWith({
      where: { id: 'consumption-1' },
      data: expect.objectContaining({ quantity: 0.2, cycle: { increment: 1 }, reversedAt: null }),
    });
  });
});
