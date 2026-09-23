import { afterEach, describe, expect, it, vi } from 'vitest';
import { ForbiddenException } from '@nestjs/common';
import { IntegrationsController } from './integrations.controller';

function makeController() {
  const prisma = {
    reservationConnection: {
      findMany: vi.fn().mockResolvedValue([]),
      findFirst: vi.fn().mockResolvedValue(null),
      update: vi.fn(),
      create: vi.fn(),
    },
    reservationSyncEvent: {
      findMany: vi.fn().mockResolvedValue([]),
      groupBy: vi.fn().mockResolvedValue([]),
    },
  } as any;
  const controller = new IntegrationsController(prisma);
  return { controller, prisma };
}

const managerScope = { venueId: 'venue-1', profileId: 'manager-1', role: 'manager', allAccess: false } as any;
const staffScope = { venueId: 'venue-1', profileId: 'staff-1', role: 'staff', allAccess: false } as any;

afterEach(() => {
  vi.restoreAllMocks();
});

describe('IntegrationsController', () => {
  describe('authorization', () => {
    it('rejects staff from the reservation overview endpoint', async () => {
      const { controller } = makeController();
      await expect(controller.getReservationIntegrationOverview(staffScope)).rejects.toThrow(ForbiddenException);
    });

    it('rejects a missing scope from the reservation overview endpoint', async () => {
      const { controller } = makeController();
      await expect(controller.getReservationIntegrationOverview(undefined as any)).rejects.toThrow(ForbiddenException);
    });

    it('rejects staff from upserting a reservation connection', async () => {
      const { controller } = makeController();
      await expect(
        controller.upsertReservationConnection(staffScope, { provider: 'opentable', status: 'connected' } as any),
      ).rejects.toThrow(ForbiddenException);
    });
  });

  describe('getReservationIntegrationOverview', () => {
    it('scopes connections and events to the venue and strips the webhook secret', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findMany.mockResolvedValue([
        {
          id: 'conn-1',
          venueId: 'venue-1',
          provider: 'opentable',
          externalVenueId: null,
          status: 'connected',
          webhookSecret: 'sha256:abc',
          lastSyncAt: null,
          createdAt: new Date(),
          updatedAt: new Date(),
        },
      ]);
      prisma.reservationSyncEvent.findMany.mockResolvedValue([
        { id: 'evt-1', venueId: 'venue-1', provider: 'opentable', processedAt: new Date() },
      ]);
      prisma.reservationSyncEvent.groupBy.mockResolvedValue([{ provider: 'opentable' }]);

      const result = await controller.getReservationIntegrationOverview(managerScope);

      expect(prisma.reservationConnection.findMany).toHaveBeenCalledWith({ where: { venueId: 'venue-1' } });
      expect(prisma.reservationSyncEvent.findMany).toHaveBeenCalledWith({
        where: { venueId: 'venue-1' },
        orderBy: { processedAt: 'desc' },
        take: 20,
      });
      expect(prisma.reservationSyncEvent.groupBy).toHaveBeenCalledWith({
        by: ['provider'],
        where: { venueId: 'venue-1', status: 'processed' },
      });
      expect(result.connections).toEqual([expect.objectContaining({ _id: 'conn-1', provider: 'opentable' })]);
      expect(result.connections[0]).not.toHaveProperty('webhookSecret');
      expect(result.connections[0]).not.toHaveProperty('id');
      expect(result.recentEvents).toEqual([expect.objectContaining({ _id: 'evt-1' })]);
      expect(result.processedProviders).toEqual(['opentable']);
    });

    it('returns empty lists when no connections or events exist', async () => {
      const { controller } = makeController();

      const result = await controller.getReservationIntegrationOverview(managerScope);

      expect(result).toEqual({ connections: [], recentEvents: [], processedProviders: [] });
    });
  });

  describe('upsertReservationConnection', () => {
    it('looks up the existing connection scoped by venue and provider', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findFirst.mockResolvedValue(null);
      prisma.reservationConnection.create.mockResolvedValue({
        id: 'conn-new',
        venueId: 'venue-1',
        provider: 'resy',
        externalVenueId: null,
        status: 'connected',
        webhookSecret: 'sha256:x',
        lastSyncAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      await controller.upsertReservationConnection(managerScope, { provider: 'resy', status: 'connected' } as any);

      expect(prisma.reservationConnection.findFirst).toHaveBeenCalledWith({
        where: { venueId: 'venue-1', provider: 'resy' },
        select: { id: true, webhookSecret: true },
      });
    });

    it('creates a new connection scoped to the venue with a fresh webhook secret', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findFirst.mockResolvedValue(null);
      prisma.reservationConnection.create.mockResolvedValue({
        id: 'conn-new',
        venueId: 'venue-1',
        provider: 'opentable',
        externalVenueId: null,
        status: 'connected',
        webhookSecret: 'sha256:hashed',
        lastSyncAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.upsertReservationConnection(managerScope, {
        provider: 'opentable',
        status: 'connected',
      } as any);

      expect(prisma.reservationConnection.create).toHaveBeenCalledWith({
        data: expect.objectContaining({
          venueId: 'venue-1',
          provider: 'opentable',
          status: 'connected',
          webhookSecret: expect.stringMatching(/^sha256:/),
        }),
      });
      expect(result._id).toBe('conn-new');
      expect(result).not.toHaveProperty('id');
      expect(result.webhookSecret).toEqual(expect.any(String));
    });

    it('updates the winning connection when a concurrent create returns P2002', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findFirst
        .mockResolvedValueOnce(null)
        .mockResolvedValueOnce({ id: 'conn-winner', webhookSecret: 'sha256:winner-secret' });
      prisma.reservationConnection.create.mockRejectedValue({ code: 'P2002' });
      prisma.reservationConnection.update.mockResolvedValue({
        id: 'conn-winner',
        venueId: 'venue-1',
        provider: 'opentable',
        externalVenueId: 'updated-venue',
        status: 'paused',
        webhookSecret: 'sha256:winner-secret',
        lastSyncAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.upsertReservationConnection(managerScope, {
        provider: 'opentable', externalVenueId: 'updated-venue', status: 'paused',
      } as any);

      expect(prisma.reservationConnection.update).toHaveBeenCalledWith({
        where: { id: 'conn-winner' },
        data: expect.not.objectContaining({ webhookSecret: expect.anything() }),
      });
      expect(result.webhookSecret).toBeNull();
    });

    it('does not rotate the secret when the existing connection already has one', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: 'sha256:already-set' });
      prisma.reservationConnection.update.mockResolvedValue({
        id: 'conn-1',
        venueId: 'venue-1',
        provider: 'opentable',
        externalVenueId: null,
        status: 'paused',
        webhookSecret: 'sha256:already-set',
        lastSyncAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.upsertReservationConnection(managerScope, {
        provider: 'opentable',
        status: 'paused',
      } as any);

      expect(prisma.reservationConnection.update).toHaveBeenCalledWith({
        where: { id: 'conn-1' },
        data: expect.not.objectContaining({ webhookSecret: expect.anything() }),
      });
      expect(result.webhookSecret).toBeNull();
    });

    it('issues a new secret when reconnecting a connection that had none', async () => {
      const { controller, prisma } = makeController();
      prisma.reservationConnection.findFirst.mockResolvedValue({ id: 'conn-1', webhookSecret: null });
      prisma.reservationConnection.update.mockResolvedValue({
        id: 'conn-1',
        venueId: 'venue-1',
        provider: 'opentable',
        externalVenueId: null,
        status: 'connected',
        webhookSecret: 'sha256:new',
        lastSyncAt: null,
        createdAt: new Date(),
        updatedAt: new Date(),
      });

      const result = await controller.upsertReservationConnection(managerScope, {
        provider: 'opentable',
        status: 'connected',
      } as any);

      expect(prisma.reservationConnection.update).toHaveBeenCalledWith({
        where: { id: 'conn-1' },
        data: expect.objectContaining({ webhookSecret: expect.stringMatching(/^sha256:/) }),
      });
      expect(result.webhookSecret).toEqual(expect.any(String));
    });
  });
});
