import { ForbiddenException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { SafeWranglerOperatorService, SAFE_TOOL_ROUTING } from './safe-wrangler-operator.service';
import { WranglerOperatorService, ALLOWED_TOOLS } from './wrangler-operator.service';

describe('SafeWranglerOperatorService', () => {
  it('normalizes and delegates an overnight CREATE_SHIFT to the scheduling service', async () => {
    const scheduling = {
      createShift: vi.fn().mockResolvedValue({
        id: 'shift-night', startMinutes: 1320, endMinutes: 1560,
        profileId: 'staff-1', status: 'scheduled',
      }),
    };
    const prisma = {
      scheduleShift: { findUniqueOrThrow: vi.fn() },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-1' }) },
    };
    const service = new SafeWranglerOperatorService(prisma as never, {} as never, scheduling as never);

    const result = await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: false },
      plan: {
        tool: 'CREATE_SHIFT',
        args: {
          date: '2026-08-23', profileId: 'staff-1', startMinutes: 1320,
          endMinutes: 120, jobTitle: 'Server', station: 'Floor',
        },
      },
    });

    expect(scheduling.createShift).toHaveBeenCalledWith(expect.objectContaining({
      venueId: 'venue-1', weekStart: '2026-08-23', dayIndex: 0,
      profileId: 'staff-1', startMinutes: 1320, endMinutes: 1560,
    }));
    expect(result.result).toEqual(expect.objectContaining({ id: 'shift-night', endMinutes: 1560 }));
  });

  it('normalizes a wrapped overnight end when updating a shift', async () => {
    const scheduling = { updateShift: vi.fn().mockResolvedValue({}) };
    const prisma = {
      scheduleShift: {
        findFirst: vi.fn().mockResolvedValue({
          id: 'shift-night', weekStart: '2026-08-23', dayIndex: 0,
          startMinutes: 1320, endMinutes: 1560, jobTitle: 'Server',
          station: 'Floor', notes: null,
        }),
        findUniqueOrThrow: vi.fn().mockResolvedValue({ id: 'shift-night', endMinutes: 1560 }),
      },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-1' }) },
    };
    const service = new SafeWranglerOperatorService(prisma as never, {} as never, scheduling as never);

    await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: false },
      plan: { tool: 'UPDATE_SHIFT', args: { shiftId: 'shift-night', endMinutes: 120 } },
    });

    expect(scheduling.updateShift).toHaveBeenCalledWith(expect.objectContaining({
      startMinutes: 1320, endMinutes: 1560,
    }));
  });

  it('rejects direct write plans from non-manager members', async () => {
    const reservations = { saveReservation: vi.fn() };
    const service = new SafeWranglerOperatorService({} as never, reservations as never, {} as never);

    await expect(service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'staff-1', fullName: 'Staff Member', role: 'staff', allAccess: false },
      plan: { tool: 'CREATE_RESERVATION', args: { guestName: 'Guest', partySize: 2, reservationTime: '2026-08-10T18:00:00.000Z' } },
    })).rejects.toBeInstanceOf(ForbiddenException);
    expect(reservations.saveReservation).not.toHaveBeenCalled();
  });

  it('rejects invalid reservation statuses before Prisma receives them', async () => {
    const prisma = {
      reservation: {
        findFirst: vi.fn().mockResolvedValue({
          id: 'reservation-1', guestName: 'Guest', partySize: 2,
          reservationTime: new Date('2026-08-10T18:00:00.000Z'), durationMinutes: 90,
          status: 'confirmed', notes: null, source: 'direct', tags: [], specialRequests: null,
          guestPhone: null, guestEmail: null,
        }),
      },
    };
    const reservations = { saveReservation: vi.fn() };
    const service = new SafeWranglerOperatorService(prisma as never, reservations as never, {} as never);

    await expect(service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: false },
      plan: { tool: 'UPDATE_RESERVATION', args: { reservationId: 'reservation-1', status: 'garbage' } },
    })).rejects.toThrow('Invalid reservation status');
    expect(reservations.saveReservation).not.toHaveBeenCalled();
  });

  it('executes CLEAR_TABLE command to clear a table status', async () => {
    const prisma = {
      floorPlan: { findFirst: vi.fn().mockResolvedValue({ id: 'plan-1' }) },
      floorTable: { findMany: vi.fn().mockResolvedValue([{ id: 'table-3', label: '3' }]) },
      tableState: {
        findFirst: vi.fn().mockResolvedValue({ id: 'ts-3', status: 'seated' }),
        update: vi.fn().mockResolvedValue({ id: 'ts-3', status: 'available' }),
      },
      tableAssignment: { updateMany: vi.fn().mockResolvedValue({ count: 1 }) },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-1' }) },
    };
    const service = new WranglerOperatorService(prisma as never);

    const result = await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: { tool: 'CLEAR_TABLE', args: { tableId: 'table-3', tableLabel: '3', status: 'available' }, summary: 'Clear table 3.', risk: 'operational_write' },
    });

    expect(result.ok).toBe(true);
    expect(result.result).toEqual({ id: 'table-3', label: '3', status: 'available' });
    expect(prisma.tableState.update).toHaveBeenCalledWith({
      where: { id: 'ts-3' },
      data: expect.objectContaining({ status: 'available', partySize: null, seatedAt: null }),
    });
    expect(prisma.tableAssignment.updateMany).toHaveBeenCalledWith({
      where: { venueId: 'venue-1', tableId: 'table-3', releasedAt: null },
      data: expect.objectContaining({ releasedAt: expect.any(Date) }),
    });
  });

  it('executes CREATE_SHIFT command to add staff to schedule', async () => {
    const prisma = {
      profile: {
        findFirst: vi.fn().mockResolvedValue({ id: 'prof-jose', fullName: 'Jose Santos', jobTitle: 'Server' }),
        findMany: vi.fn().mockResolvedValue([{ id: 'prof-jose', fullName: 'Jose Santos', jobTitle: 'Server' }]),
      },
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([]),
        create: vi.fn().mockResolvedValue({
          id: 'shift-100',
          startMinutes: 900,
          endMinutes: 1440,
          profileId: 'prof-jose',
          status: 'scheduled',
        }),
      },
      venue: { findUnique: vi.fn().mockResolvedValue({ schedulePublishedAt: null }) },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-2' }) },
    };
    const service = new WranglerOperatorService(prisma as never);

    const result = await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: {
        tool: 'CREATE_SHIFT',
        args: { date: '2026-08-03', startMinutes: 900, endMinutes: 1440, profileId: 'prof-jose', staffName: 'Jose Santos', jobTitle: 'Server' },
        summary: 'Add shift for Jose Santos.',
        risk: 'operational_write',
      },
    });

    expect(result.ok).toBe(true);
    expect(result.result).toEqual({
      id: 'shift-100',
      date: '2026-08-03',
      weekStart: '2026-08-02',
      dayIndex: 1,
      startMinutes: 900,
      endMinutes: 1440,
      profileId: 'prof-jose',
      staffName: 'Jose Santos',
      status: 'scheduled',
    });
  });

  it('executes CREATE_CRM_LEAD command across CRM domain', async () => {
    const prisma = {
      crmLead: {
        create: vi.fn().mockResolvedValue({ id: 'lead-1', fullName: 'Acme Corp Party', status: 'new' }),
      },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-3' }) },
    };
    const service = new WranglerOperatorService(prisma as never);

    const result = await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: {
        tool: 'CREATE_CRM_LEAD',
        args: { fullName: 'Acme Corp Party', company: 'Acme Corp' },
        summary: 'Create CRM lead for Acme Corp Party.',
        risk: 'operational_write',
      },
    });

    expect(result.ok).toBe(true);
    expect(result.result).toEqual({ id: 'lead-1', fullName: 'Acme Corp Party', status: 'new' });
    expect(prisma.crmLead.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ venueId: 'venue-1', fullName: 'Acme Corp Party', status: 'new' }),
    });
  });

  it('executes UPDATE_ITEM_86 command across Inventory domain', async () => {
    const prisma = {
      prepBoardItem: {
        create: vi.fn().mockResolvedValue({ id: 'prep-1', title: 'Tuna Tartare', kind: 'eighty_six', status: 'open' }),
      },
      auditLog: { create: vi.fn().mockResolvedValue({ id: 'audit-4' }) },
    };
    const service = new WranglerOperatorService(prisma as never);

    const result = await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: {
        tool: 'UPDATE_ITEM_86',
        args: { itemName: 'Tuna Tartare', isEightySix: true },
        summary: '86 item Tuna Tartare.',
        risk: 'operational_write',
      },
    });

    expect(result.ok).toBe(true);
    expect(result.result).toEqual({ id: 'prep-1', itemName: 'Tuna Tartare', isEightySix: true });
  });

  it('does not invent a table target when fallback parsing lacks one', async () => {
    const service = new WranglerOperatorService({} as never);

    const parsed = (service as any).fallbackParse('clear table');

    expect(parsed).toEqual({ tool: 'CLEAR_TABLE', args: {}, summary: 'Clear the requested table.' });
  });

  it('routes both singular and plural lead phrasing to the CRM tool', async () => {
    // Tightening the trigger from includes('lead') to a word-boundary match
    // dropped the plural, and "show me my leads" then fell all the way through
    // to the no-AI BadRequestException.
    const service = new WranglerOperatorService({} as never);

    for (const text of ['show me my leads', 'find the lead for Acme']) {
      expect((service as any).fallbackParse(text)).toEqual(
        expect.objectContaining({ tool: 'FIND_CRM_LEAD' }),
      );
    }
  });

  it('still ignores a word that merely contains "lead"', async () => {
    // "leader" is not a lead. Allowing the plural must not reopen the loose
    // substring match E10 removed: an ambiguous phrase belongs with the AI
    // planner, not misrouted to CRM.
    const service = new WranglerOperatorService({} as never);

    expect(() => (service as any).fallbackParse('who is the team leader')).toThrow(
      'AI operator requires GEMINI_API_KEY',
    );
  });

  it('rejects invalid table statuses before Prisma receives them', async () => {
    const prisma = {
      floorPlan: { findFirst: vi.fn().mockResolvedValue({ id: 'plan-1' }) },
      floorTable: { findMany: vi.fn().mockResolvedValue([{ id: 'table-3', label: '3' }]) },
      tableState: { findFirst: vi.fn() },
    };
    const service = new WranglerOperatorService(prisma as never);

    await expect(service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: { tool: 'UPDATE_TABLE_STATUS', args: { tableLabel: '3', status: 'destroyed' }, summary: 'Update table 3.', risk: 'operational_write' },
    })).rejects.toThrow('Invalid table status');
    expect(prisma.floorTable.findMany).not.toHaveBeenCalled();
  });

  it('never searches tables outside the venue when there is no active floor plan', async () => {
    // FloorTable has no venueId column, so the tenant-isolation extension cannot
    // scope it. This mock mirrors Prisma semantics — a where clause with no
    // floorPlanId/floorPlan predicate matches every venue's tables — so a
    // regression that drops the predicate resolves the foreign table below.
    const foreignTable = { id: 'table-other-venue', label: '3' };
    const findMany = vi.fn(async ({ where }: any) => {
      const scopedToVenue = where?.floorPlan?.venueId === 'venue-1' || typeof where?.floorPlanId === 'string';
      return scopedToVenue ? [] : [foreignTable];
    });
    const prisma = {
      floorPlan: { findFirst: vi.fn().mockResolvedValue(null) },
      floorTable: { findMany },
      tableState: { findFirst: vi.fn(), update: vi.fn() },
      tableAssignment: { updateMany: vi.fn() },
      auditLog: { create: vi.fn() },
    };
    const service = new WranglerOperatorService(prisma as never);

    await expect(service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: true },
      plan: { tool: 'CLEAR_TABLE', args: { tableLabel: '3', status: 'available' }, summary: 'Clear table 3.', risk: 'operational_write' },
    })).rejects.toThrow('No table found matching "3"');

    for (const [args] of findMany.mock.calls) {
      expect(args.where.floorPlan?.venueId).toBe('venue-1');
    }
    expect(prisma.tableState.update).not.toHaveBeenCalled();
  });
});

describe('SafeWranglerOperatorService tool routing', () => {
  /**
   * The routing map replaced an inline allowlist whose default pointed the
   * wrong way: any tool not in the list fell through to the less-validated
   * parser path silently. Nothing was exploitable — the parser re-checks
   * ALLOWED_TOOLS and guards ADD_STAFF/REMOVE_STAFF individually — but a tool
   * added to ALLOWED_TOOLS was downgraded without anyone deciding to.
   */
  it('classifies every tool in ALLOWED_TOOLS', () => {
    // The Record<OperatorTool, ...> type already makes an unclassified tool a
    // compile error. This asserts it at runtime too, so the guarantee survives
    // someone widening the type or reaching for a cast.
    const unclassified = ALLOWED_TOOLS.filter((tool) => SAFE_TOOL_ROUTING[tool] === undefined);
    expect(unclassified).toEqual([]);
  });

  it('routes every tool the service reimplements through the strict path', () => {
    // These six are re-validated and re-executed here rather than in the
    // parser, so they must never be marked 'parser'.
    for (const tool of ['CREATE_RESERVATION', 'UPDATE_RESERVATION', 'CREATE_SHIFT', 'UPDATE_SHIFT', 'ASSIGN_SHIFT', 'CORRECT_PUNCH'] as const) {
      expect(SAFE_TOOL_ROUTING[tool]).toBe('strict');
    }
  });

  it('sends an unrecognised tool to the parser, which rejects it', async () => {
    const parserExecute = vi
      .spyOn(WranglerOperatorService.prototype, 'execute')
      .mockResolvedValue({ ok: false } as never);
    const service = new SafeWranglerOperatorService({} as never, {} as never, {} as never);

    await service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'manager-1', fullName: 'Manager', role: 'manager', allAccess: false },
      plan: { tool: 'TOTALLY_MADE_UP', args: {} },
    });

    // Unknown tools must not silently take the strict branch's write path; the
    // parser is where ALLOWED_TOOLS is enforced.
    expect(parserExecute).toHaveBeenCalledTimes(1);
    parserExecute.mockRestore();
  });

  it('still refuses a non-manager before routing anywhere', async () => {
    const service = new SafeWranglerOperatorService({} as never, {} as never, {} as never);
    await expect(service.execute({
      venueId: 'venue-1',
      actor: { profileId: 'staff-1', fullName: 'Staff', role: 'staff', allAccess: false },
      plan: { tool: 'CREATE_RESERVATION', args: {} },
    })).rejects.toBeInstanceOf(ForbiddenException);
  });
});
