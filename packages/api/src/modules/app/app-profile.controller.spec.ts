import { BadRequestException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { AppProfileController } from './app-profile.controller';

const user = { sub: 'user-1', venueId: 'venue-1' } as any;
const manager = { id: 'manager-1', role: 'manager', allAccess: false, venueId: 'venue-1' };
const target = { id: 'staff-1', venueId: 'venue-1', role: 'staff', photoKey: null, allAccess: false, email: 'staff@example.com', fullName: 'Staff', jobTitle: 'Server' };

function setup() {
  const prisma: any = { profile: { findFirst: vi.fn(), findUnique: vi.fn(), findUniqueOrThrow: vi.fn(), update: vi.fn(), updateMany: vi.fn().mockResolvedValue({ count: 1 }) }, objectDeletionJob: { create: vi.fn().mockResolvedValue({ id: 'delete-old' }) } };
  prisma.$transaction = vi.fn(async (callback: any) => callback(prisma));
  const profiles: any = { getProfile: vi.fn(), requireManagerProfile: vi.fn().mockResolvedValue(manager) };
  const mediaAccess: any = { createPath: vi.fn().mockReturnValue('/photo?token=signed'), assertToken: vi.fn() };
  const images: any = { uploadProfilePhoto: vi.fn().mockResolvedValue('profiles/venue-1/abcd'), delete: vi.fn().mockResolvedValue(undefined), getObject: vi.fn() };
  const scanner: any = { assertClean: vi.fn().mockResolvedValue(undefined) };
  return { controller: new AppProfileController(prisma, profiles, mediaAccess, images, scanner), prisma, profiles, mediaAccess, images, scanner };
}

describe('AppProfileController', () => {
  it('updates only the current user profile and preserves omitted fields', async () => {
    const { controller, prisma, profiles } = setup();
    profiles.getProfile.mockResolvedValue(target);
    prisma.profile.update.mockResolvedValue({ ...target, phone: '555-0100' });
    await controller.updateMyProfile(user, { phone: '555-0100' });
    expect(prisma.profile.update).toHaveBeenCalledWith({ where: { id: target.id }, data: { phone: '555-0100' } });
  });

  it('allows a user to clear their date of birth', async () => {
    const { controller, prisma, profiles } = setup();
    profiles.getProfile.mockResolvedValue(target);
    prisma.profile.update.mockResolvedValue({ ...target, dateOfBirth: null });
    await controller.updateMyProfile(user, { dateOfBirth: null });
    expect(prisma.profile.update).toHaveBeenCalledWith({ where: { id: target.id }, data: { dateOfBirth: null } });
  });

  it('rejects manager photo upload outside the active venue', async () => {
    const { controller, prisma, images } = setup();
    prisma.profile.findFirst.mockResolvedValue(null);
    await expect(controller.uploadStaffPhoto(user, 'other-venue-staff', { dataBase64: 'AA==' })).rejects.toThrow(NotFoundException);
    expect(prisma.profile.findFirst).toHaveBeenCalledWith({ where: { id: 'other-venue-staff', venueId: 'venue-1', OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] } });
    expect(images.uploadProfilePhoto).not.toHaveBeenCalled();
  });

  it('does not allow a manager to replace an owner photo', async () => {
    const { controller, prisma, images } = setup();
    prisma.profile.findFirst.mockResolvedValue({ ...target, role: 'owner' });
    await expect(controller.uploadStaffPhoto(user, target.id, { dataBase64: 'AA==' })).rejects.toThrow(ForbiddenException);
    expect(images.uploadProfilePhoto).not.toHaveBeenCalled();
  });

  it('rejects non-image bytes before storage', async () => {
    const { controller, profiles, images } = setup();
    profiles.getProfile.mockResolvedValue(target);
    await expect(controller.uploadMyPhoto(user, { dataBase64: Buffer.from('not an image').toString('base64') })).rejects.toThrow(BadRequestException);
    expect(images.uploadProfilePhoto).not.toHaveBeenCalled();
  });

  it('stores a valid self photo and queues the replaced object for deletion', async () => {
    const { controller, profiles, prisma, images, scanner } = setup();
    profiles.getProfile.mockResolvedValue({ ...target, photoKey: 'profiles/venue-1/old' });
    prisma.profile.findUniqueOrThrow.mockResolvedValue({ ...target, photoKey: 'profiles/venue-1/abcd' });
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0x00]);
    await expect(controller.uploadMyPhoto(user, { dataBase64: jpeg.toString('base64'), mimeType: 'image/jpeg' })).resolves.toEqual({ photoUrl: '/photo?token=signed' });
    expect(scanner.assertClean).toHaveBeenCalledWith(jpeg);
    expect(images.uploadProfilePhoto).toHaveBeenCalledWith(jpeg, 'image/jpeg', 'venue-1');
    expect(prisma.objectDeletionJob.create).toHaveBeenCalledWith({ data: { objectKeys: ['profiles/venue-1/old'] } });
  });

  it('requires the signed token to read private photos', async () => {
    const { controller, prisma, mediaAccess, images } = setup();
    prisma.profile.findUnique.mockResolvedValue({ id: target.id, venueId: target.venueId, photoKey: 'profiles/venue-1/abcd' });
    mediaAccess.assertToken.mockImplementation(() => { throw new Error('expired'); });
    await expect(controller.getPhoto(target.id, 'bad', {} as any)).rejects.toThrow(NotFoundException);
    expect(images.getObject).not.toHaveBeenCalled();
  });
});
