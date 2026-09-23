import { Injectable } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { PrismaService } from '../../prisma/prisma.service';
import { InventoryMovementService } from './inventory-movement.service';
import { convertQuantity } from './inventory-units';

type PosCheckForInventory = {
  venueId: string; provider: string; externalCheckId: string;
  status: string; menuItems: unknown; openedAt: Date; closedAt: Date | null;
};

const normalizedName = (value: string) => value.trim().toLocaleLowerCase('en-US');
const operationId = (...parts: string[]) => `pos_${createHash('sha256').update(parts.join('\0')).digest('hex')}`;

@Injectable()
export class InventoryRecipeService {
  constructor(private readonly prisma: PrismaService, private readonly movements: InventoryMovementService) {}

  /** Applies recipe depletion once when a POS check is paid, and restores it if voided. */
  async processPosCheck(check: PosCheckForInventory) {
    const key = { venueId: check.venueId, provider: check.provider as any, externalCheckId: check.externalCheckId };
    if (check.status === 'void') {
      const existing = await this.prisma.posInventoryConsumption.findMany({ where: { ...key, reversedAt: null } });
      for (const row of existing) {
        if (row.appliedQuantity > 0) await this.movements.record({
          venueId: check.venueId, itemId: row.itemId, createdBy: 'pos', movementType: 'received',
          quantity: row.appliedQuantity, notes: `Voided POS check ${check.externalCheckId}`,
          operationId: operationId(check.venueId, check.provider, check.externalCheckId, row.itemId, `void-${row.cycle}`),
        });
        await this.prisma.posInventoryConsumption.update({ where: { id: row.id }, data: { reversedAt: new Date() } });
      }
      return;
    }
    if (check.status !== 'paid' || !Array.isArray(check.menuItems)) return;

    const sold = new Map<string, number>();
    for (const raw of check.menuItems) {
      if (!raw || typeof raw !== 'object') continue;
      const row = raw as { name?: unknown; quantity?: unknown };
      if (typeof row.name !== 'string') continue;
      const qty = Number(row.quantity ?? 1);
      if (!Number.isFinite(qty) || qty <= 0) continue;
      const name = normalizedName(row.name);
      sold.set(name, (sold.get(name) ?? 0) + qty);
    }
    if (!sold.size) return;

    const priorRows = await this.prisma.posInventoryConsumption.findMany({ where: key });
    const priorByItem = new Map(priorRows.map((row) => [row.itemId, row]));
    const required = new Map<string, number>();
    // A reinstated paid check uses the same recorded recipe quantities it used
    // before the void, even if a manager has since edited the recipe.
    for (const row of priorRows) {
      if (row.reversedAt) required.set(row.itemId, row.quantity);
    }

    // A recipe takes effect for sales closed after it was saved. This prevents
    // a retry of an older paid check from deducting stock after a later count.
    const soldAt = check.closedAt ?? check.openedAt;
    const recipes = await this.prisma.inventoryRecipe.findMany({
      where: { venueId: check.venueId, normalizedName: { in: [...sold.keys()] }, updatedAt: { lte: soldAt } },
      include: { ingredients: { include: { item: true } } },
    });
    for (const recipe of recipes) {
      const soldCount = sold.get(recipe.normalizedName) ?? 0;
      for (const ingredient of recipe.ingredients) {
        if (priorByItem.has(ingredient.itemId)) continue;
        const stockUnits = convertQuantity(ingredient.quantity, ingredient.unit, ingredient.item.baseUnit) / ingredient.item.baseQuantity * soldCount;
        required.set(ingredient.itemId, (required.get(ingredient.itemId) ?? 0) + stockUnits);
      }
    }

    for (const [itemId, quantity] of required) {
      const opId = operationId(check.venueId, check.provider, check.externalCheckId, itemId, 'paid');
      const recorded = priorByItem.get(itemId);
      if (recorded && recorded.reversedAt === null) continue;
      // Ledger movement itself is idempotent, protecting retries if the worker
      // is interrupted between the stock update and consumption marker write.
      const movement = await this.movements.record({
        venueId: check.venueId, itemId, createdBy: 'pos', movementType: 'transfer',
        quantity: -quantity, notes: `POS sale ${check.externalCheckId}`,
        operationId: recorded ? operationId(check.venueId, check.provider, check.externalCheckId, itemId, `paid-${recorded.cycle + 1}`) : opId,
      });
      const applied = Math.max(0, movement.movement.previousOnHand - movement.movement.nextOnHand);
      if (recorded) {
        await this.prisma.posInventoryConsumption.update({ where: { id: recorded.id }, data: { quantity, appliedQuantity: applied, cycle: { increment: 1 }, reversedAt: null } });
      } else {
        await this.prisma.posInventoryConsumption.create({ data: { ...key, itemId, quantity, appliedQuantity: applied } });
      }
    }
  }
}
