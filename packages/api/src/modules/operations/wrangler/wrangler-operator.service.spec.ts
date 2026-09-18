import { BadRequestException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { WranglerOperatorService } from './wrangler-operator.service';

describe('Wrangler inventory writes', () => {
  const actor = { profileId: 'p1', fullName: 'Manager', role: 'manager', allAccess: false };
  const plan = { tool: 'UPDATE_BAR_STOCK', args: { itemName: 'House Vodka', onHand: 3 }, summary: 'Count', risk: 'write' };

  it('uses the shared movement service with an exact venue-scoped item', async () => {
    const findMany = vi.fn(async () => [{ id: 'i1', name: 'House Vodka', parLevel: 5 }]);
    const record = vi.fn(async () => ({ movement: { nextOnHand: 3 } }));
    const service = new WranglerOperatorService({ barInventoryItem: { findMany }, auditLog: { create: vi.fn() } } as never, { record } as never);
    await service.execute({ venueId: 'v1', actor, plan } as never);
    expect(findMany).toHaveBeenCalledWith({ where: { venueId: 'v1', name: { equals: 'House Vodka', mode: 'insensitive' } }, take: 2 });
    expect(record).toHaveBeenCalledWith(expect.objectContaining({ venueId: 'v1', itemId: 'i1', createdBy: 'p1', movementType: 'count', quantity: 3 }));
  });

  it('passes no operationId when the caller sends no requestId (unchanged behavior for older clients)', async () => {
    const findMany = vi.fn(async () => [{ id: 'i1', name: 'House Vodka', parLevel: 5 }]);
    const record = vi.fn(async () => ({ movement: { nextOnHand: 3 } }));
    const service = new WranglerOperatorService({ barInventoryItem: { findMany }, auditLog: { create: vi.fn() } } as never, { record } as never);

    await service.execute({ venueId: 'v1', actor, plan } as never);

    expect(record).toHaveBeenCalledWith(expect.objectContaining({ operationId: undefined }));
  });

  it('derives a stable operationId from requestId so a retried execute() can be deduped', async () => {
    const findMany = vi.fn(async () => [{ id: 'i1', name: 'House Vodka', parLevel: 5 }]);
    const record = vi.fn(async () => ({ movement: { nextOnHand: 3 } }));
    const service = new WranglerOperatorService({ barInventoryItem: { findMany }, auditLog: { create: vi.fn() } } as never, { record } as never);

    await service.execute({ venueId: 'v1', actor, plan, requestId: 'req-abc' } as never);

    expect(record).toHaveBeenCalledWith(expect.objectContaining({ operationId: 'wrangler-req-abc' }));
  });

  it('rejects an ambiguous inventory name without updating stock', async () => {
    const record = vi.fn();
    const service = new WranglerOperatorService({ barInventoryItem: { findMany: vi.fn(async () => [{ id: 'i1' }, { id: 'i2' }]) } } as never, { record } as never);
    await expect(service.execute({ venueId: 'v1', actor, plan } as never)).rejects.toThrow('ambiguous');
    expect(record).not.toHaveBeenCalled();
  });
});

// Covers the read-path tool branches inside the private executeRead() method
// (FIND_RESERVATION, LIST_WAITLIST, FIND_CRM_LEAD, SEARCH_CHAT, LIST_INVENTORY,
// GET_SALES_PULSE, LIST_INTEGRATIONS, FIND_STAFF, LIST_SCHEDULE, LIST_CLOCKS).
// Called directly via the same (service as any).<privateMethod>(...) pattern
// already used for fallbackParse() in safe-wrangler-operator.service.spec.ts,
// since executeRead is not part of the public API.
describe('WranglerOperatorService executeRead', () => {
  const actor = { profileId: 'profile-1', fullName: 'Casey Manager', role: 'manager', allAccess: false };

  function callRead(prisma: any, tool: string, args: Record<string, unknown> = {}, timezone: string | null | undefined = 'UTC') {
    const service = new WranglerOperatorService(prisma as never);
    return (service as any).executeRead('venue-1', timezone, tool, args, actor);
  }

  describe('FIND_RESERVATION', () => {
    it('filters by guest name and maps reservation rows', async () => {
      const prisma = {
        reservation: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'res-1', guestName: 'Jane Doe', partySize: 4, reservationTime: new Date('2026-08-03T18:00:00Z'), status: 'confirmed', source: 'direct', notes: 'Window seat' },
          ]),
        },
      };

      const result = await callRead(prisma, 'FIND_RESERVATION', { guestName: 'Jane' });

      expect(prisma.reservation.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ venueId: 'venue-1', deletedAt: null, guestName: { contains: 'Jane', mode: 'insensitive' } }),
      }));
      expect(result).toEqual([
        { id: 'res-1', guestName: 'Jane Doe', partySize: 4, reservationTime: new Date('2026-08-03T18:00:00Z').getTime(), status: 'confirmed', source: 'direct', notes: 'Window seat' },
      ]);
    });

    it('narrows to a date range when a date is supplied and defaults notes to null', async () => {
      const prisma = {
        reservation: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'res-2', guestName: 'Sam', partySize: 2, reservationTime: new Date('2026-08-03T20:00:00Z'), status: 'requested', source: 'wrangler_operator', notes: null },
          ]),
        },
      };

      const result = await callRead(prisma, 'FIND_RESERVATION', { date: '2026-08-03' });

      expect(prisma.reservation.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({
          venueId: 'venue-1',
          reservationTime: { gte: expect.any(Date), lt: expect.any(Date) },
        }),
      }));
      expect(result[0].notes).toBeNull();
    });

    it('returns an empty list when nothing matches', async () => {
      const prisma = { reservation: { findMany: vi.fn().mockResolvedValue([]) } };
      const result = await callRead(prisma, 'FIND_RESERVATION', {});
      expect(result).toEqual([]);
    });
  });

  describe('LIST_WAITLIST', () => {
    it('returns waiting entries scoped to the venue, oldest first', async () => {
      const prisma = {
        waitlist: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'wl-1', guestName: 'Alex', partySize: 3, requestedAt: new Date('2026-08-03T18:00:00Z'), guestPhone: '555-1234', notes: null },
          ]),
        },
      };

      const result = await callRead(prisma, 'LIST_WAITLIST', {});

      expect(prisma.waitlist.findMany).toHaveBeenCalledWith({
        where: { venueId: 'venue-1', status: 'waiting' },
        orderBy: { requestedAt: 'asc' },
        take: 50,
      });
      expect(result).toEqual([
        { id: 'wl-1', guestName: 'Alex', partySize: 3, requestedAt: new Date('2026-08-03T18:00:00Z').getTime(), phone: '555-1234', notes: null },
      ]);
    });

    it('defaults missing phone and notes to null', async () => {
      const prisma = {
        waitlist: { findMany: vi.fn().mockResolvedValue([{ id: 'wl-2', guestName: 'Bo', partySize: 1, requestedAt: new Date('2026-08-03T18:00:00Z'), guestPhone: null, notes: null }]) },
      };
      const result = await callRead(prisma, 'LIST_WAITLIST', {});
      expect(result[0]).toEqual(expect.objectContaining({ phone: null, notes: null }));
    });
  });

  describe('FIND_CRM_LEAD', () => {
    it('filters by name and status and maps lead rows', async () => {
      const prisma = {
        crmLead: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'lead-1', fullName: 'Acme Corp', email: 'a@acme.com', company: 'Acme', status: 'qualified', estimatedValueCents: 500000 },
          ]),
        },
      };

      const result = await callRead(prisma, 'FIND_CRM_LEAD', { name: 'Acme', status: 'qualified' });

      expect(prisma.crmLead.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ venueId: 'venue-1', deletedAt: null, fullName: { contains: 'Acme', mode: 'insensitive' }, status: 'qualified' }),
      }));
      expect(result).toEqual([{ id: 'lead-1', fullName: 'Acme Corp', email: 'a@acme.com', company: 'Acme', status: 'qualified', estimatedValueCents: 500000 }]);
    });

    it('returns an empty list when no leads match', async () => {
      const prisma = { crmLead: { findMany: vi.fn().mockResolvedValue([]) } };
      const result = await callRead(prisma, 'FIND_CRM_LEAD', {});
      expect(result).toEqual([]);
    });
  });

  describe('SEARCH_CHAT', () => {
    it('scopes messages to the caller\'s own conversations and filters by query text', async () => {
      const prisma = {
        conversation: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'conv-1', type: 'group', memberIds: ['profile-1', 'profile-2'] },
            { id: 'conv-2', type: 'dm', memberIds: ['profile-1', 'profile-3'] },
          ]),
        },
        message: { findMany: vi.fn().mockResolvedValue([{ id: 'msg-1', text: 'run food to table 5', createdAt: new Date('2026-08-03T18:00:00Z'), conversationId: 'conv-1' }]) },
      };

      const result = await callRead(prisma, 'SEARCH_CHAT', { query: 'food' });

      expect(prisma.conversation.findMany).toHaveBeenCalledWith({
        where: { venueId: 'venue-1', memberIds: { has: 'profile-1' } },
        take: 20,
      });
      expect(prisma.message.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ conversationId: { in: ['conv-1', 'conv-2'] }, text: { contains: 'food', mode: 'insensitive' } }),
      }));
      expect(result).toEqual([{ id: 'msg-1', text: 'run food to table 5', createdAt: new Date('2026-08-03T18:00:00Z').getTime(), conversationId: 'conv-1' }]);
    });

    it('excludes a venue conversation the caller does not belong to', async () => {
      const prisma = {
        conversation: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'conv-1', type: 'dm', memberIds: ['profile-1', 'profile-2'] },
            // A row the membership predicate would not return; belt and braces
            // in case the filter is ever loosened, the access rule still holds.
            { id: 'private-dm', type: 'dm', memberIds: ['profile-8', 'profile-9'] },
          ]),
        },
        message: { findMany: vi.fn().mockResolvedValue([]) },
      };

      await callRead(prisma, 'SEARCH_CHAT', { query: 'raise' });

      expect(prisma.message.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ conversationId: { in: ['conv-1'] } }),
      }));
    });

    it('searches with an empty conversation scope when the caller has no conversations', async () => {
      const prisma = {
        conversation: { findMany: vi.fn().mockResolvedValue([]) },
        message: { findMany: vi.fn().mockResolvedValue([]) },
      };

      const result = await callRead(prisma, 'SEARCH_CHAT', {});

      expect(prisma.message.findMany).toHaveBeenCalledWith(expect.objectContaining({ where: expect.objectContaining({ conversationId: { in: [] } }) }));
      expect(result).toEqual([]);
    });
  });

  describe('LIST_INVENTORY', () => {
    it('combines bar inventory with open 86 items and flags low stock', async () => {
      const prisma = {
        barInventoryItem: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'item-1', name: 'Vodka', category: 'liquor', onHand: 2, parLevel: 5 },
            { id: 'item-2', name: 'Gin', category: 'liquor', onHand: 10, parLevel: 5 },
          ]),
        },
        prepBoardItem: { findMany: vi.fn().mockResolvedValue([{ id: 'prep-1', title: 'Tuna Tartare', station: 'kitchen' }]) },
      };

      const result = await callRead(prisma, 'LIST_INVENTORY', {});

      expect(prisma.prepBoardItem.findMany).toHaveBeenCalledWith(expect.objectContaining({ where: { venueId: 'venue-1', kind: 'eighty_six', status: 'open' } }));
      expect(result).toEqual({
        inventory: [
          { id: 'item-1', name: 'Vodka', category: 'liquor', onHand: 2, parLevel: 5, isLow: true },
          { id: 'item-2', name: 'Gin', category: 'liquor', onHand: 10, parLevel: 5, isLow: false },
        ],
        eightySixItems: [{ id: 'prep-1', title: 'Tuna Tartare', station: 'kitchen' }],
      });
    });

    it('filters to low-stock items only when lowStockOnly is set', async () => {
      const prisma = {
        barInventoryItem: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'item-1', name: 'Vodka', category: 'liquor', onHand: 2, parLevel: 5 },
            { id: 'item-2', name: 'Gin', category: 'liquor', onHand: 10, parLevel: 5 },
          ]),
        },
        prepBoardItem: { findMany: vi.fn().mockResolvedValue([]) },
      };

      const result = await callRead(prisma, 'LIST_INVENTORY', { lowStockOnly: true });

      expect(result.inventory).toEqual([{ id: 'item-1', name: 'Vodka', category: 'liquor', onHand: 2, parLevel: 5, isLow: true }]);
    });
  });

  describe('GET_SALES_PULSE', () => {
    it('totals checks for the given date and counts by status', async () => {
      const prisma = {
        posCheck: {
          findMany: vi.fn().mockResolvedValue([
            { totalCents: 5000, status: 'paid' },
            { totalCents: 3000, status: 'open' },
            { totalCents: null, status: 'open' },
          ]),
        },
      };

      const result = await callRead(prisma, 'GET_SALES_PULSE', { date: '2026-08-03' });

      expect(prisma.posCheck.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ venueId: 'venue-1', openedAt: { gte: expect.any(Date), lt: expect.any(Date) } }),
      }));
      expect(result).toEqual({ date: '2026-08-03', totalSalesCents: 8000, totalChecks: 3, openChecks: 2, paidChecks: 1 });
    });

    it('returns zeroed totals when there are no checks for the day', async () => {
      const prisma = { posCheck: { findMany: vi.fn().mockResolvedValue([]) } };
      const result = await callRead(prisma, 'GET_SALES_PULSE', { date: '2026-08-03' });
      expect(result).toEqual({ date: '2026-08-03', totalSalesCents: 0, totalChecks: 0, openChecks: 0, paidChecks: 0 });
    });
  });

  describe('LIST_INTEGRATIONS', () => {
    it('maps POS and reservation connections for the venue', async () => {
      const prisma = {
        posConnection: { findMany: vi.fn().mockResolvedValue([{ provider: 'toast', status: 'connected', lastSyncAt: new Date('2026-08-03T12:00:00Z') }]) },
        reservationConnection: { findMany: vi.fn().mockResolvedValue([{ provider: 'opentable', status: 'error', lastSyncAt: null }]) },
      };

      const result = await callRead(prisma, 'LIST_INTEGRATIONS', {});

      expect(prisma.posConnection.findMany).toHaveBeenCalledWith({ where: { venueId: 'venue-1' } });
      expect(prisma.reservationConnection.findMany).toHaveBeenCalledWith({ where: { venueId: 'venue-1' } });
      expect(result).toEqual({
        posConnections: [{ provider: 'toast', status: 'connected', lastSyncAt: new Date('2026-08-03T12:00:00Z').getTime() }],
        reservationConnections: [{ provider: 'opentable', status: 'error', lastSyncAt: null }],
      });
    });

    it('returns empty connection lists when nothing is connected', async () => {
      const prisma = {
        posConnection: { findMany: vi.fn().mockResolvedValue([]) },
        reservationConnection: { findMany: vi.fn().mockResolvedValue([]) },
      };
      const result = await callRead(prisma, 'LIST_INTEGRATIONS', {});
      expect(result).toEqual({ posConnections: [], reservationConnections: [] });
    });
  });

  describe('FIND_STAFF', () => {
    it('filters active staff by name and job title', async () => {
      const prisma = {
        profile: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'prof-1', fullName: 'Jose Santos', email: 'jose@venue.com', role: 'staff', jobTitle: 'Server', membershipStatus: 'active' },
          ]),
        },
      };

      const result = await callRead(prisma, 'FIND_STAFF', { staffName: 'Jose', jobTitle: 'Server' });

      expect(prisma.profile.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({
          venueId: 'venue-1',
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
          fullName: { contains: 'Jose', mode: 'insensitive' },
          jobTitle: { contains: 'Server', mode: 'insensitive' },
        }),
      }));
      expect(result).toEqual([{ id: 'prof-1', fullName: 'Jose Santos', email: 'jose@venue.com', role: 'staff', jobTitle: 'Server', membershipStatus: 'active' }]);
    });

    it('returns an empty roster when no staff match', async () => {
      const prisma = { profile: { findMany: vi.fn().mockResolvedValue([]) } };
      const result = await callRead(prisma, 'FIND_STAFF', {});
      expect(result).toEqual([]);
    });
  });

  describe('LIST_SCHEDULE', () => {
    it('resolves staff by name before filtering shifts and includes staff names', async () => {
      const prisma = {
        profile: { findMany: vi.fn().mockResolvedValue([{ id: 'prof-1', fullName: 'Jose Santos' }]) },
        scheduleShift: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'shift-1', startMinutes: 900, endMinutes: 1080, jobTitle: 'Server', station: 'Floor', status: 'scheduled', profileId: 'prof-1', profile: { id: 'prof-1', fullName: 'Jose Santos' } },
          ]),
        },
      };

      const result = await callRead(prisma, 'LIST_SCHEDULE', { date: '2026-08-03', staffName: 'Jose' });

      expect(prisma.profile.findMany).toHaveBeenCalled();
      expect(prisma.scheduleShift.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({
          venueId: 'venue-1',
          profileId: { in: ['prof-1'] },
          OR: expect.arrayContaining([
            { weekStart: '2026-08-02', dayIndex: 1 },
          ]),
        }),
      }));
      expect(result).toEqual([
        { id: 'shift-1', date: '2026-08-03', startMinutes: 900, endMinutes: 1080, jobTitle: 'Server', station: 'Floor', status: 'scheduled', profileId: 'prof-1', staffName: 'Jose Santos' },
      ]);
    });

    it('lists the whole day when no staff name is given, defaulting open shifts to a null staffName', async () => {
      const prisma = {
        scheduleShift: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'shift-2', startMinutes: 600, endMinutes: 900, jobTitle: 'Cook', station: 'Kitchen', status: 'open', profileId: null, profile: null },
          ]),
        },
      };

      const result = await callRead(prisma, 'LIST_SCHEDULE', { date: '2026-08-03' });

      expect(prisma.scheduleShift.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({
          venueId: 'venue-1',
          OR: expect.arrayContaining([
            { weekStart: '2026-08-02', dayIndex: 1 },
          ]),
        }),
      }));
      expect(result[0]).toEqual(expect.objectContaining({ staffName: null, profileId: null }));
    });
  });

  describe('LIST_CLOCKS', () => {
    it('resolves staff by name before filtering time entries', async () => {
      const prisma = {
        profile: { findMany: vi.fn().mockResolvedValue([{ id: 'prof-1', fullName: 'Jose Santos' }]) },
        timeEntry: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'te-1', profileId: 'prof-1', clockInAt: new Date('2026-08-03T15:00:00Z'), clockOutAt: new Date('2026-08-03T23:00:00Z'), isOpen: false, breaks: [], profile: { id: 'prof-1', fullName: 'Jose Santos' } },
          ]),
        },
      };

      const result = await callRead(prisma, 'LIST_CLOCKS', { date: '2026-08-03', staffName: 'Jose' });

      expect(prisma.timeEntry.findMany).toHaveBeenCalledWith(expect.objectContaining({
        where: expect.objectContaining({ venueId: 'venue-1', clockInAt: { gte: expect.any(Date), lt: expect.any(Date) }, profileId: { in: ['prof-1'] } }),
      }));
      expect(result).toEqual([
        { id: 'te-1', profileId: 'prof-1', staffName: 'Jose Santos', clockInAt: new Date('2026-08-03T15:00:00Z').getTime(), clockOutAt: new Date('2026-08-03T23:00:00Z').getTime(), isOpen: false, breaks: [] },
      ]);
    });

    it('treats a punch with no clock-out as still open', async () => {
      const prisma = {
        timeEntry: {
          findMany: vi.fn().mockResolvedValue([
            { id: 'te-2', profileId: 'prof-2', clockInAt: new Date('2026-08-03T15:00:00Z'), clockOutAt: null, isOpen: true, breaks: [], profile: null },
          ]),
        },
      };

      const result = await callRead(prisma, 'LIST_CLOCKS', { date: '2026-08-03' });

      expect(result[0]).toEqual(expect.objectContaining({ staffName: null, clockOutAt: null, isOpen: true }));
    });
  });

  it('rejects a tool that is not part of the read-path', async () => {
    const prisma = {};
    await expect(callRead(prisma, 'CLEAR_TABLE', {})).rejects.toBeInstanceOf(BadRequestException);
  });
});

describe('WranglerOperatorService assertNoShiftOverlap', () => {
  it('loads adjacent weeks so Sunday overnight collides with Monday morning', async () => {
    const prisma = {
      scheduleShift: {
        findMany: vi.fn().mockResolvedValue([
          { weekStart: '2026-08-23', dayIndex: 0, startMinutes: 1320, endMinutes: 1560 },
        ]),
      },
    };
    const service = new WranglerOperatorService(prisma as never);

    await expect(
      (service as any).assertNoShiftOverlap('venue-1', 'profile-1', '2026-08-23', 1, 60, 180),
    ).rejects.toThrow('That staff member already has an overlapping shift');

    expect(prisma.scheduleShift.findMany).toHaveBeenCalledWith(expect.objectContaining({
      where: expect.objectContaining({
        weekStart: { in: ['2026-08-16', '2026-08-23', '2026-08-30'] },
      }),
    }));
  });
});
