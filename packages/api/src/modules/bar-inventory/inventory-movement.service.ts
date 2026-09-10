import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { BarStockMovementType } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { NotificationsService } from '../../notifications/notifications.service';

export type InventoryMovementInput = {
  venueId: string;
  itemId: string;
  createdBy: string;
  movementType: BarStockMovementType;
  quantity: number;
  notes?: string;
  operationId?: string;
};

@Injectable()
export class InventoryMovementService {
  private readonly logger = new Logger(InventoryMovementService.name);

  constructor(private readonly prisma: PrismaService, private readonly notifications: NotificationsService) {}

  async record(input: InventoryMovementInput) {
    const { venueId, itemId, movementType, quantity, createdBy, operationId } = input;
    if (!Number.isFinite(quantity) || !Object.values(BarStockMovementType).includes(movementType)) {
      throw new BadRequestException('Invalid inventory movement');
    }
    if ((movementType === 'waste' || movementType === 'comp') && quantity > 0) {
      throw new BadRequestException(`A ${movementType} movement must reduce stock. Use a negative quantity.`);
    }
    if (movementType === 'received' && quantity < 0) {
      throw new BadRequestException('A received movement must be positive.');
    }
    const notes = input.notes?.trim() || null;
    const result = await this.prisma.$transaction(async (tx) => {
      if (operationId) {
        const requestLock = `bar-operation-${venueId}-${operationId}`;
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${requestLock}))`;
        const existing = await tx.barInventoryMovement.findFirst({ where: { venueId, operationId } });
        if (existing) {
          if (existing.itemId !== itemId || existing.movementType !== movementType || existing.quantity !== quantity || existing.notes !== notes || existing.createdBy !== createdBy) {
            throw new ConflictException('Inventory operation ID was already used for a different request');
          }
          return { movement: existing, item: null, replayed: true };
        }
      }
      const lockKey = `bar-inventory-${itemId}`;
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${lockKey}))`;
      const item = await tx.barInventoryItem.findFirst({ where: { id: itemId, venueId } });
      if (!item) throw new NotFoundException('Item not found');
      const previousOnHand = item.onHand;
      const nextOnHand = movementType === 'count' ? Math.max(0, quantity) : Math.max(0, previousOnHand + quantity);
      const now = new Date();
      await tx.barInventoryItem.update({ where: { id: item.id }, data: {
        onHand: nextOnHand,
        lastCountedAt: movementType === 'count' ? now : item.lastCountedAt,
        updatedAt: now,
      } });
      const movement = await tx.barInventoryMovement.create({ data: {
        venueId, itemId, movementType, quantity, previousOnHand, nextOnHand, notes,
        unitCostCents: item.unitCostCents ?? null, createdBy, createdAt: now,
        ...(operationId ? { operationId } : {}),
      } });
      return { movement, item, replayed: false };
    });
    if (result.item) {
      void this.alert(result.item, result.movement).catch((error: unknown) => {
        this.logger.error(`Inventory alert delivery failed: ${error instanceof Error ? error.message : String(error)}`);
      });
    }
    return result;
  }

  private async alert(
    item: { name: string; parLevel: number; unitCostCents: number | null },
    movement: { venueId: string; previousOnHand: number; nextOnHand: number; movementType: string; quantity: number },
  ) {
    const { venueId, previousOnHand, nextOnHand, movementType, quantity } = movement;
    if (previousOnHand >= item.parLevel && nextOnHand < item.parLevel) {
      await this.notifications.notifyManagers({ venueId, kind: 'inventory_low_stock', title: `Low stock: ${item.name}`,
        body: `${nextOnHand} ${nextOnHand === 1 ? 'unit' : 'units'} remaining (par ${item.parLevel})` });
    }
    if ((movementType === 'waste' || movementType === 'comp') && item.unitCostCents != null) {
      const lossCents = Math.abs(quantity) * item.unitCostCents;
      if (lossCents >= 5000) {
        await this.notifications.notifyManagers({ venueId, kind: 'inventory_large_loss', title: `Large ${movementType} recorded`,
          body: `${Math.abs(quantity)} × ${item.name} — est. $${(lossCents / 100).toFixed(2)} loss` });
      }
    }
  }
}
