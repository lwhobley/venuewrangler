import { Module } from '@nestjs/common';
import { BillingModule } from '../../billing/billing.module';
import { PrismaModule } from '../../prisma/prisma.module';
import { GustoClient } from './gusto-client';
import { GustoPayrollService } from './gusto-payroll.service';
import { PayrollConnectService } from './payroll-connect.service';
import { PayrollController } from './payroll.controller';
import { QuickBooksClient } from './quickbooks-client';
import { SquareClient } from './square-client';

@Module({
  imports: [PrismaModule, BillingModule],
  controllers: [PayrollController],
  providers: [GustoClient, GustoPayrollService, QuickBooksClient, SquareClient, PayrollConnectService],
})
export class PayrollModule {}
