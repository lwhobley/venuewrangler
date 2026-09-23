import { Module } from '@nestjs/common';
import { BarInventoryController } from './bar-inventory.controller';
import { BarInventoryReportsService } from './bar-inventory-reports.service';
import { PrismaModule } from '../../prisma/prisma.module';
import { BillingModule } from '../../billing/billing.module';
import { NotificationsModule } from '../../notifications/notifications.module';
import { EmailModule } from '../../email/email.module';
import { BarInventoryParserService } from './bar-inventory-parser.service';
import { InventoryMovementService } from './inventory-movement.service';
import { InventoryRecipeService } from './inventory-recipe.service';

@Module({
  imports: [PrismaModule, BillingModule, NotificationsModule, EmailModule],
  controllers: [BarInventoryController],
  providers: [BarInventoryParserService, BarInventoryReportsService, InventoryMovementService, InventoryRecipeService],
  exports: [InventoryMovementService, InventoryRecipeService],
})
export class BarInventoryModule {}
