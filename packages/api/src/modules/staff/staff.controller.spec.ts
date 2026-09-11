import { afterEach, describe, expect, it, vi } from 'vitest';
import { ForbiddenException, NotFoundException } from '@nestjs/common';
import { StaffController } from './staff.controller';

function makeController() {
  const prisma: any = {
    profile: {
      findMany: vi.fn().mockResolvedValue([]),
      findUnique: vi.fn().mockResolvedValue(null),
      update: vi.fn().mockImplementation(async ({ where, data }: any) => ({ id: where.id, ...data })),
      create: vi.fn().mockImplementation(async ({ data }: any) => ({ id: 'new-profile-1', ...data })),
      count: vi.fn().mockResolvedValue(5),
    },
    session: {
      deleteMany: vi.fn().mockResolvedValue({ count: 0 }),
    },
    timeEntry: {
      updateMany: vi.fn().mockResolvedValue({ count: 1 }),
    },
    team: {
      upsert: vi.fn().mockResolvedValue({ id: 'team-1' }),
    },
    $executeRaw: vi.fn().mockResolvedValue(undefined),
  };
  prisma.$transaction = vi.fn().mockImplementation(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma));

  const email = { send: vi.fn().mockResolvedValue(undefined) } as any;
  const audit = { record: vi.fn().mockResolvedValue(undefined) } as any;
  const controller = new StaffController(prisma, email, audit);
  return { controller, prisma, email, audit };
}

const managerScope = { venueId: 'venue-1', venueName: 'Test Venue', profileId: 'manager-1', role: 'manager', allAccess: false } as any;
const staffScope = { venueId: 'venue-1', venueName: 'Test Venue', profileId: 'staff-1', role: 'staff', allAccess: false } as any;
const ownerScope = { venueId: 'venue-1', venueName: 'Test Venue', profileId: 'owner-1', role: 'owner', allAccess: false } as any;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('StaffController', () => {
  describe('listVenueStaff', () => {
    it('returns an empty list for a missing scope', async () => {
      const { controller } = makeController();
      await expect(controller.listVenueStaff(undefined as any)).resolves.toEqual([]);
    });

    it('returns an empty list for non-admin roles', async () => {
      const { controller, prisma } = makeController();
      await expect(controller.listVenueStaff(staffScope)).resolves.toEqual([]);
      expect(prisma.profile.findMany).not.toHaveBeenCalled();
    });

    it('lists staff scoped by venueId, sorted by name', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        { id: 'staff-2', email: 'zed@x.com', fullName: 'Zed', role: 'staff', jobTitle: 'Server', phone: null, altPhone: null, address: null, dateOfBirth: null, certifications: [], venueId: 'venue-1', allAccess: false, sickHoursAccrued: 0, ptoHoursAccrued: 0 },
        { id: 'staff-1', email: 'alex@x.com', fullName: 'Alex', role: 'staff', jobTitle: 'Server', phone: null, altPhone: null, address: null, dateOfBirth: null, certifications: [], venueId: 'venue-1', allAccess: false, sickHoursAccrued: 0, ptoHoursAccrued: 0 },
      ]);

      const result = await controller.listVenueStaff(managerScope);

      expect(prisma.profile.findMany).toHaveBeenCalledWith({
        where: { venueId: 'venue-1', OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
      });
      expect(result.map((r: any) => r.fullName)).toEqual(['Alex', 'Zed']);
    });
  });

  describe('upsertVenueStaff authorization', () => {
    it('rejects a missing scope', async () => {
      const { controller } = makeController();
      await expect(
        controller.upsertVenueStaff(undefined as any, {
          email: 'new@x.com',
          fullName: 'New Person',
          role: 'staff',
          jobTitle: 'Server',
        } as any),
      ).rejects.toThrow(ForbiddenException);
    });

    it('rejects non-admin roles', async () => {
      const { controller } = makeController();
      await expect(
        controller.upsertVenueStaff(staffScope, {
          email: 'new@x.com',
          fullName: 'New Person',
          role: 'staff',
          jobTitle: 'Server',
        } as any),
      ).rejects.toThrow(ForbiddenException);
    });

    it('blocks a manager from assigning an elevated role', async () => {
      const { controller } = makeController();
      await expect(
        controller.upsertVenueStaff(managerScope, {
          email: 'new@x.com',
          fullName: 'New Person',
          role: 'manager',
          jobTitle: 'Manager',
        } as any),
      ).rejects.toThrow('Managers cannot assign admin, owner, or manager roles');
    });

    it('allows an owner to assign an elevated role', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([]);

      await expect(
        controller.upsertVenueStaff(ownerScope, {
          email: 'new@x.com',
          fullName: 'New Manager',
          role: 'manager',
          jobTitle: 'Manager',
        } as any),
      ).resolves.toEqual(expect.objectContaining({ role: 'manager' }));
    });
  });

  describe('upsertVenueStaff role-hierarchy on existing members', () => {
    it('does not let a manager re-role another manager', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'manager-2',
          email: 'other-manager@x.com',
          fullName: 'Other Manager',
          role: 'manager',
          jobTitle: 'Manager',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);

      // Demoting to a non-elevated role so this exercises the canManageRole
      // rank check in assertCanManageTarget, not the earlier elevated-role gate.
      await expect(
        controller.upsertVenueStaff(managerScope, {
          email: 'other-manager@x.com',
          fullName: 'Other Manager',
          role: 'staff',
          jobTitle: 'Server',
        } as any),
      ).rejects.toThrow('You cannot modify this staff member');
      expect(prisma.profile.update).not.toHaveBeenCalled();
    });

    it('lets an owner manage another owner', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'owner-2',
          email: 'other-owner@x.com',
          fullName: 'Other Owner',
          role: 'owner',
          jobTitle: 'Owner',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);
      prisma.profile.count.mockResolvedValue(2);

      await expect(
        controller.upsertVenueStaff(ownerScope, {
          email: 'other-owner@x.com',
          fullName: 'Other Owner Updated',
          role: 'owner',
          jobTitle: 'Co-Owner',
        } as any),
      ).resolves.toEqual(expect.objectContaining({ fullName: 'Other Owner Updated' }));
      expect(prisma.profile.update).toHaveBeenCalled();
    });

    it('allows editing your own profile even though a peer manager could not manage your rank', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'manager-1',
          email: 'manager@x.com',
          fullName: 'Manager Name',
          role: 'manager',
          jobTitle: 'Manager',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-manager-1',
        },
      ]);

      // Self-editing down to a non-elevated role: this would be forbidden if
      // attempted by another manager (equal rank, not owner/admin tier), but
      // assertCanManageTarget always allows editing your own profile.
      await expect(
        controller.upsertVenueStaff(managerScope, {
          email: 'manager@x.com',
          fullName: 'Manager Name Updated',
          role: 'staff',
          jobTitle: 'Manager',
        } as any),
      ).resolves.toEqual(expect.objectContaining({ fullName: 'Manager Name Updated' }));
    });

    it('blocks demoting the last owner/admin in the venue', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'owner-2',
          email: 'other-owner@x.com',
          fullName: 'Other Owner',
          role: 'owner',
          jobTitle: 'Owner',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);
      prisma.profile.count.mockResolvedValue(1);

      await expect(
        controller.upsertVenueStaff(ownerScope, {
          email: 'other-owner@x.com',
          fullName: 'Other Owner',
          role: 'staff',
          jobTitle: 'Server',
        } as any),
      ).rejects.toThrow('You cannot remove the last owner or admin from the venue');
      expect(prisma.profile.update).not.toHaveBeenCalled();
    });

    it('allows demoting an owner when another owner/admin remains', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'owner-2',
          email: 'other-owner@x.com',
          fullName: 'Other Owner',
          role: 'owner',
          jobTitle: 'Owner',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);
      prisma.profile.count.mockResolvedValue(2);

      await expect(
        controller.upsertVenueStaff(ownerScope, {
          email: 'other-owner@x.com',
          fullName: 'Other Owner',
          role: 'staff',
          jobTitle: 'Server',
        } as any),
      ).resolves.toEqual(expect.objectContaining({ role: 'staff' }));
      expect(prisma.session.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-2' } });
    });

    it('does not clear sessions when the role is unchanged', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'staff-2',
          email: 'staffer@x.com',
          fullName: 'Staffer',
          role: 'staff',
          jobTitle: 'Server',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);

      await controller.upsertVenueStaff(managerScope, {
        email: 'staffer@x.com',
        fullName: 'Staffer',
        role: 'staff',
        jobTitle: 'Head Server',
      } as any);

      expect(prisma.session.deleteMany).not.toHaveBeenCalled();
    });

    it('sends a profile-updated email for existing members', async () => {
      const { controller, prisma, email } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'staff-2',
          email: 'staffer@x.com',
          fullName: 'Staffer',
          role: 'staff',
          jobTitle: 'Server',
          phone: null,
          altPhone: null,
          address: null,
          dateOfBirth: null,
          certifications: [],
          userId: 'user-2',
        },
      ]);

      await controller.upsertVenueStaff(managerScope, {
        email: 'staffer@x.com',
        fullName: 'Staffer',
        role: 'staff',
        jobTitle: 'Head Server',
      } as any);

      expect(email.send).toHaveBeenCalledWith(
        expect.objectContaining({ to: 'staffer@x.com', subject: expect.stringContaining('profile was updated') }),
      );
    });
  });

  describe('upsertVenueStaff creating new members', () => {
    it('creates a new profile and invites them by email', async () => {
      const { controller, prisma, email } = makeController();
      prisma.profile.findMany.mockResolvedValue([]);

      const result = await controller.upsertVenueStaff(managerScope, {
        email: 'New.Hire@X.com',
        fullName: 'New Hire',
        role: 'staff',
        jobTitle: 'Server',
      } as any);

      expect(prisma.profile.create).toHaveBeenCalledWith({
        data: expect.objectContaining({
          email: 'new.hire@x.com',
          fullName: 'New Hire',
          role: 'staff',
          jobTitle: 'Server',
          venueId: 'venue-1',
        }),
      });
      expect(result).toEqual(expect.objectContaining({ fullName: 'New Hire' }));
      expect(email.send).toHaveBeenCalledWith(
        expect.objectContaining({ to: 'new.hire@x.com', subject: expect.stringContaining('added to the team') }),
      );
    });

    it('syncs the team member count when a new profile is created', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findMany.mockResolvedValue([]);
      prisma.profile.count.mockResolvedValue(7);

      await controller.upsertVenueStaff(managerScope, {
        email: 'new@x.com',
        fullName: 'New Person',
        role: 'staff',
        jobTitle: 'Server',
      } as any);

      expect(prisma.team.upsert).toHaveBeenCalledWith({
        where: { venueId: 'venue-1' },
        create: expect.objectContaining({ venueId: 'venue-1', memberCount: 7 }),
        update: { memberCount: 7 },
      });
    });
  });

  describe('deactivateVenueStaff', () => {
    it('rejects a missing scope', async () => {
      const { controller } = makeController();
      await expect(controller.deactivateVenueStaff(undefined as any, 'staff-2')).rejects.toThrow(ForbiddenException);
    });

    it('rejects non-admin roles', async () => {
      const { controller } = makeController();
      await expect(controller.deactivateVenueStaff(staffScope, 'staff-2')).rejects.toThrow(ForbiddenException);
    });

    it('throws NotFoundException when the staff member does not exist', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue(null);
      await expect(controller.deactivateVenueStaff(managerScope, 'missing-id')).rejects.toThrow(NotFoundException);
    });

    it('rejects deactivating a staff member from a different venue', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue({ id: 'staff-2', venueId: 'venue-2', role: 'staff' });
      await expect(controller.deactivateVenueStaff(managerScope, 'staff-2')).rejects.toThrow(
        'Staff member does not belong to this venue',
      );
    });

    it('does not let a manager deactivate another manager', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue({ id: 'manager-2', venueId: 'venue-1', role: 'manager', userId: 'user-2' });

      await expect(controller.deactivateVenueStaff(managerScope, 'manager-2')).rejects.toThrow(
        'You cannot modify this staff member',
      );
      expect(prisma.profile.update).not.toHaveBeenCalled();
    });

    it('blocks removing the last owner/admin from the venue', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue({ id: 'owner-2', venueId: 'venue-1', role: 'owner', userId: 'user-2' });
      prisma.profile.count.mockResolvedValue(1);

      await expect(controller.deactivateVenueStaff(ownerScope, 'owner-2')).rejects.toThrow(
        'You cannot remove the last owner or admin from the venue',
      );
      expect(prisma.profile.update).not.toHaveBeenCalled();
    });

    it('deactivates a staff member, clears sessions, and syncs the team count', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue({ id: 'staff-2', venueId: 'venue-1', role: 'staff', userId: 'user-2' });
      prisma.profile.count.mockResolvedValue(0);

      const result = await controller.deactivateVenueStaff(managerScope, 'staff-2');

      expect(prisma.profile.update).toHaveBeenCalledWith({
        where: { id: 'staff-2' },
        data: { membershipStatus: 'revoked' },
      });
      expect(prisma.timeEntry.updateMany).toHaveBeenCalledWith({
        where: { profileId: 'staff-2', isOpen: true },
        data: { isOpen: false, clockOutAt: expect.any(Date) },
      });
      expect(prisma.profile.count).toHaveBeenCalledWith({
        where: {
          userId: 'user-2',
          venueId: { not: 'venue-1' },
          venue: { isNot: null },
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        },
      });
      expect(prisma.session.deleteMany).toHaveBeenCalledWith({ where: { userId: 'user-2' } });
      expect(prisma.team.upsert).toHaveBeenCalledWith({
        where: { venueId: 'venue-1' },
        create: expect.objectContaining({ venueId: 'venue-1', memberCount: expect.any(Number) }),
        update: { memberCount: expect.any(Number) },
      });
      expect(result).toEqual(expect.objectContaining({ _id: 'staff-2' }));
    });

    it('keeps sessions alive when the staff member is still active at another venue', async () => {
      const { controller, prisma } = makeController();
      prisma.profile.findUnique.mockResolvedValue({ id: 'staff-2', venueId: 'venue-1', role: 'staff', userId: 'user-2' });
      prisma.profile.count.mockResolvedValue(1);

      await controller.deactivateVenueStaff(managerScope, 'staff-2');

      expect(prisma.profile.update).toHaveBeenCalledWith({
        where: { id: 'staff-2' },
        data: { membershipStatus: 'revoked' },
      });
      expect(prisma.session.deleteMany).not.toHaveBeenCalled();
    });

    it('records an audit event when deactivating a staff member', async () => {
      const { controller, prisma, audit } = makeController();
      prisma.profile.findUnique.mockResolvedValue({
        id: 'staff-2',
        venueId: 'venue-1',
        role: 'staff',
        fullName: 'Jane Doe',
        userId: 'user-2',
      });
      prisma.profile.count.mockResolvedValue(0);

      await controller.deactivateVenueStaff(managerScope, 'staff-2');

      expect(audit.record).toHaveBeenCalledWith(
        expect.objectContaining({
          action: 'staff_deactivated',
          entityType: 'profile',
          entityId: 'staff-2',
          venueId: 'venue-1',
          actorProfileId: 'manager-1',
          targetProfileId: 'staff-2',
        }),
        expect.anything(),
      );
    });
  });

  describe('audit logging for upsertVenueStaff', () => {
    it('records staff_created when adding a new staff member', async () => {
      const { controller, prisma, audit } = makeController();
      prisma.profile.findMany.mockResolvedValue([]);
      prisma.profile.create.mockResolvedValue({
        id: 'new-staff-1',
        email: 'new@example.com',
        fullName: 'New Staff',
        role: 'server',
        jobTitle: 'Server',
        venueId: 'venue-1',
      });

      await controller.upsertVenueStaff(managerScope, {
        email: 'new@example.com',
        fullName: 'New Staff',
        role: 'server',
        jobTitle: 'Server',
      });

      expect(audit.record).toHaveBeenCalledWith(
        expect.objectContaining({
          action: 'staff_created',
          entityType: 'profile',
          entityId: 'new-staff-1',
          venueId: 'venue-1',
          actorProfileId: 'manager-1',
        }),
        expect.anything(),
      );
    });

    it('records staff_updated when updating an existing staff member', async () => {
      const { controller, prisma, audit } = makeController();
      prisma.profile.findMany.mockResolvedValue([
        {
          id: 'existing-staff-1',
          email: 'existing@example.com',
          fullName: 'Existing Staff',
          role: 'server',
          jobTitle: 'Server',
          venueId: 'venue-1',
        },
      ]);
      prisma.profile.update.mockResolvedValue({
        id: 'existing-staff-1',
        email: 'existing@example.com',
        fullName: 'Existing Staff Updated',
        role: 'server',
        jobTitle: 'Lead Server',
        venueId: 'venue-1',
      });

      await controller.upsertVenueStaff(managerScope, {
        email: 'existing@example.com',
        fullName: 'Existing Staff Updated',
        role: 'server',
        jobTitle: 'Lead Server',
      });

      expect(audit.record).toHaveBeenCalledWith(
        expect.objectContaining({
          action: 'staff_updated',
          entityType: 'profile',
          entityId: 'existing-staff-1',
          venueId: 'venue-1',
          actorProfileId: 'manager-1',
        }),
        expect.anything(),
      );
    });
  });
});
