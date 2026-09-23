import { Module } from '@nestjs/common';
import { PosController } from './pos.controller';
import { PrismaModule } from '../../prisma/prisma.module';
import { BillingModule } from '../../billing/billing.module';
import { BarInventoryModule } from '../bar-inventory/bar-inventory.module';

@Module({ imports: [PrismaModule, BillingModule, BarInventoryModule], controllers: [PosController] })
export class PosModule {}
