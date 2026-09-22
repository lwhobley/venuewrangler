import { describe, it, expect, vi } from 'vitest';
import { Reflector } from '@nestjs/core';
import { of } from 'rxjs';
import { AUDITED_METADATA_KEY, AuditedOptions } from './audited.decorator';
import { AuditInterceptor } from './audit.interceptor';
import { AuditService } from './audit.service';
import { PayrollController } from '../payroll/payroll.controller';
import { AppController } from '../app/app.controller';
import { ReservationsController } from '../reservations/reservations.controller';
import { DocumentsController } from '../documents/documents.controller';
import { GuestsController } from '../guests/guests.controller';
import { PosController } from '../pos/pos.controller';

describe('Audit Coverage & Interceptor (VW-A03)', () => {
  const reflector = new Reflector();

  const EXPECTED_AUDITED_HANDLERS: Array<{
    controller: any;
    method: string;
    expectedAction: string;
    expectedEntityType: string;
  }> = [
    {
      controller: PayrollController,
      method: 'exportPayrollCsv',
      expectedAction: 'payroll.export',
      expectedEntityType: 'payroll',
    },
    {
      controller: PayrollController,
      method: 'pushGusto',
      expectedAction: 'payroll.gusto_push',
      expectedEntityType: 'payroll',
    },
    {
      controller: PayrollController,
      method: 'mapPayrollEmployee',
      expectedAction: 'payroll.employee_mapped',
      expectedEntityType: 'profile',
    },
    {
      controller: PayrollController,
      method: 'pushProvider',
      expectedAction: 'payroll.provider_push',
      expectedEntityType: 'payroll',
    },
    {
      controller: AppController,
      method: 'exportTimeEntriesCsv',
      expectedAction: 'time_entries.export',
      expectedEntityType: 'time_clock',
    },
    {
      controller: AppController,
      method: 'rotateVenueJoinCode',
      expectedAction: 'join_code.rotate',
      expectedEntityType: 'venue',
    },
    {
      controller: AppController,
      method: 'createInvite',
      expectedAction: 'invite.create',
      expectedEntityType: 'invite',
    },
    {
      controller: AppController,
      method: 'deleteMyAccount',
      expectedAction: 'account.delete',
      expectedEntityType: 'account',
    },
    {
      controller: ReservationsController,
      method: 'exportReservationsCsv',
      expectedAction: 'reservations.export',
      expectedEntityType: 'reservation',
    },
    {
      controller: DocumentsController,
      method: 'upload',
      expectedAction: 'document.upload',
      expectedEntityType: 'document',
    },
    {
      controller: DocumentsController,
      method: 'access',
      expectedAction: 'document.access',
      expectedEntityType: 'document',
    },
    {
      controller: DocumentsController,
      method: 'remove',
      expectedAction: 'document.delete',
      expectedEntityType: 'document',
    },
    {
      controller: GuestsController,
      method: 'rotateLeadsWebhookSecret',
      expectedAction: 'webhook_secret.rotate_leads',
      expectedEntityType: 'venue',
    },
    {
      controller: PosController,
      method: 'rotatePosConnectionSecret',
      expectedAction: 'webhook_secret.rotate_pos',
      expectedEntityType: 'pos_connection',
    },
  ];

  it('verifies that all 11 critical endpoints are decorated with @Audited', () => {
    for (const target of EXPECTED_AUDITED_HANDLERS) {
      const handler = target.controller.prototype[target.method];
      expect(handler, `Handler ${target.controller.name}.${target.method} should exist`).toBeDefined();
      const meta = reflector.get<AuditedOptions>(AUDITED_METADATA_KEY, handler);
      expect(meta, `Handler ${target.controller.name}.${target.method} should be decorated with @Audited`).toBeDefined();
      expect(meta?.action).toBe(target.expectedAction);
      expect(meta?.entityType).toBe(target.expectedEntityType);
    }
  });

  it('records an audit event with actor, venue, and IP when an audited endpoint completes', async () => {
    const mockAuditRecord = vi.fn().mockResolvedValue(undefined);
    const mockAuditService = { record: mockAuditRecord } as unknown as AuditService;
    const interceptor = new AuditInterceptor(reflector, mockAuditService);

    const mockRequest = {
      venueScope: {
        venueId: 'ven_123',
        profileId: 'prof_456',
        fullName: 'Jane Doe',
        role: 'manager',
      },
      ip: '198.51.100.42',
      headers: { 'user-agent': 'VenueWranglerApp/1.0' },
      originalUrl: '/v1/payroll/export-csv',
      method: 'GET',
    };

    const mockContext = {
      getHandler: () => PayrollController.prototype.exportPayrollCsv,
      switchToHttp: () => ({
        getRequest: () => mockRequest,
      }),
    } as any;

    const mockCallHandler = {
      handle: () => of('employee,hours\nJane,40'),
    };

    const result$ = interceptor.intercept(mockContext, mockCallHandler);

    await new Promise<void>((resolve, reject) => {
      result$.subscribe({
        next: () => {
          // Allow microtask in tap to finish
          setTimeout(() => {
            try {
              expect(mockAuditRecord).toHaveBeenCalledTimes(1);
              expect(mockAuditRecord).toHaveBeenCalledWith(
                expect.objectContaining({
                  venueId: 'ven_123',
                  actorProfileId: 'prof_456',
                  actorName: 'Jane Doe',
                  actorRole: 'manager',
                  entityType: 'payroll',
                  action: 'payroll.export',
                  ipAddress: '198.51.100.42',
                  metadata: expect.objectContaining({
                    resultSize: 22,
                  }),
                }),
              );
              resolve();
            } catch (err) {
              reject(err);
            }
          }, 10);
        },
        error: reject,
      });
    });
  });
});
