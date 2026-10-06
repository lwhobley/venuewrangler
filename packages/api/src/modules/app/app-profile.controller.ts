import { BadRequestException, Body, ConflictException, Controller, ForbiddenException, Get, NotFoundException, Param, Patch, Post, Query, Res, UseGuards } from '@nestjs/common';
import { IsDateString, IsOptional, IsString, MaxLength } from 'class-validator';
import type { Response } from 'express';
import { AuthGuard } from '../../auth/auth.guard';
import { canManageRole } from '../../auth/roles';
import type { AuthUser } from '../../auth/auth.guard';
import { CurrentUser } from '../../auth/current-user.decorator';
import { Public } from '../../auth/public.decorator';
import { SkipVenueScope } from '../../venue/skip-venue-scope.decorator';
import { assertAllowedImageBytes } from '../../common/image-bytes';
import { streamPrivateImage } from '../../common/stream-private-image';
import { PrismaService } from '../../prisma/prisma.service';
import { DocumentMalwareScannerService } from '../documents/document-malware-scanner.service';
import { MediaAccessService } from '../chat/media-access.service';
import { S3ImageService } from '../chat/s3-image.service';
import { mapProfile } from './app-mappers';
import { profilePhotoUrl } from './profile-photo';
import { ProfileService } from './profile.service';

// A field left out of the request body is unchanged; an explicit `null` clears it. (A
// previous version of this DTO typed these as `?: string`, which `@IsOptional()` accepted
// as a request body `null` would too — class-validator's `@IsOptional()` skips every
// validator on `null` the same as on `undefined` — but the handler then called
// `.trim()` on it directly and crashed. The `| null` here documents the contract the
// handler below actually implements.)
class UpdateMyProfileDto {
  @IsOptional() @IsString() @MaxLength(120) preferredName?: string | null;
  @IsOptional() @IsString() @MaxLength(50) phone?: string | null;
  @IsOptional() @IsString() @MaxLength(50) altPhone?: string | null;
  @IsOptional() @IsString() @MaxLength(255) address?: string | null;
  @IsOptional() @IsDateString() dateOfBirth?: string | null;
  @IsOptional() @IsString() @MaxLength(120) emergencyContactName?: string | null;
  @IsOptional() @IsString() @MaxLength(80) emergencyContactRelationship?: string | null;
  @IsOptional() @IsString() @MaxLength(50) emergencyContactPhone?: string | null;
}

class UploadProfilePhotoDto {
  @IsString() @MaxLength(7_000_000) dataBase64!: string;
  @IsOptional() @IsString() @MaxLength(32) mimeType?: string;
}

@Controller('v1/app')
export class AppProfileController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly profiles: ProfileService,
    private readonly mediaAccess: MediaAccessService,
    private readonly images: S3ImageService,
    private readonly malwareScanner: DocumentMalwareScannerService,
  ) {}

  @UseGuards(AuthGuard)
  @Get('me/hr-profile')
  async getMyProfile(@CurrentUser() user: AuthUser) {
    const profile = await this.profiles.getProfile(user);
    if (!profile || (profile.membershipStatus && profile.membershipStatus !== 'active')) {
      throw new NotFoundException('Profile not found');
    }
    return { ...mapProfile(profile), photoUrl: profilePhotoUrl(profile, this.mediaAccess) };
  }

  @UseGuards(AuthGuard)
  @Patch('me/hr-profile')
  async updateMyProfile(@CurrentUser() user: AuthUser, @Body() body: UpdateMyProfileDto) {
    const profile = await this.profiles.getProfile(user);
    if (!profile || (profile.membershipStatus && profile.membershipStatus !== 'active')) {
      throw new NotFoundException('Profile not found');
    }
    const updated = await this.prisma.profile.update({
      where: { id: profile.id },
      data: {
        ...(body.preferredName !== undefined ? { preferredName: body.preferredName?.trim() || null } : {}),
        ...(body.phone !== undefined ? { phone: body.phone?.trim() || null } : {}),
        ...(body.altPhone !== undefined ? { altPhone: body.altPhone?.trim() || null } : {}),
        ...(body.address !== undefined ? { address: body.address?.trim() || null } : {}),
        ...(body.dateOfBirth !== undefined ? { dateOfBirth: body.dateOfBirth ? new Date(body.dateOfBirth) : null } : {}),
        ...(body.emergencyContactName !== undefined ? { emergencyContactName: body.emergencyContactName?.trim() || null } : {}),
        ...(body.emergencyContactRelationship !== undefined ? { emergencyContactRelationship: body.emergencyContactRelationship?.trim() || null } : {}),
        ...(body.emergencyContactPhone !== undefined ? { emergencyContactPhone: body.emergencyContactPhone?.trim() || null } : {}),
      },
    });
    return { ...mapProfile(updated), photoUrl: profilePhotoUrl(updated, this.mediaAccess) };
  }

  @UseGuards(AuthGuard)
  @Post('me/photo')
  async uploadMyPhoto(@CurrentUser() user: AuthUser, @Body() body: UploadProfilePhotoDto) {
    const profile = await this.profiles.getProfile(user);
    if (!profile || (profile.membershipStatus && profile.membershipStatus !== 'active')) {
      throw new NotFoundException('Profile not found');
    }
    return this.uploadPhoto(profile, body);
  }

  @UseGuards(AuthGuard)
  @Post('staff/:id/photo')
  async uploadStaffPhoto(@CurrentUser() user: AuthUser, @Param('id') id: string, @Body() body: UploadProfilePhotoDto) {
    const viewer = await this.profiles.requireManagerProfile(user);
    const target = await this.prisma.profile.findFirst({
      where: { id, venueId: viewer.venueId!, OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] },
    });
    if (!target) throw new NotFoundException('Staff member not found');
    // Same rule the rest of profile management uses (canManageRole): a manager may not
    // touch another manager's — or anyone equal-or-higher-ranked's — photo, only an
    // owner/admin may manage a peer. This used to be a weaker inline check that let a
    // manager overwrite another manager's photo.
    if (target.id !== viewer.id && !canManageRole(viewer.role, target.role, viewer.allAccess)) {
      throw new ForbiddenException('Not authorized');
    }
    return this.uploadPhoto(target, body);
  }

  private async uploadPhoto(profile: { id: string; venueId: string | null; photoKey: string | null }, body: UploadProfilePhotoDto) {
    const data = Buffer.from(body.dataBase64, 'base64');
    if (!data.length || data.length > 5 * 1024 * 1024) throw new BadRequestException('Photo must be between 1 byte and 5MB');
    const mime = assertAllowedImageBytes(data, body.mimeType);
    await this.malwareScanner.assertClean(data);
    const key = await this.images.uploadProfilePhoto(data, mime, profile.venueId ?? profile.id);
    let updated;
    try {
      updated = await this.prisma.$transaction(async (tx) => {
        const changed = await tx.profile.updateMany({
          where: {
            id: profile.id, venueId: profile.venueId, photoKey: profile.photoKey,
            OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
          },
          data: { photoKey: key, photoMimeType: mime },
        });
        if (changed.count !== 1) throw new ConflictException('Profile changed. Please retry the photo upload.');
        if (profile.photoKey) {
          await tx.objectDeletionJob.create({ data: { objectKeys: [profile.photoKey] } });
        }
        return tx.profile.findUniqueOrThrow({ where: { id: profile.id } });
      });
    } catch (error) {
      await this.images.delete(key).catch(() => undefined);
      throw error;
    }
    return { photoUrl: profilePhotoUrl(updated, this.mediaAccess) };
  }

  @Public()
  @SkipVenueScope()
  @Get('profile-photos/:id')
  async getPhoto(@Param('id') id: string, @Query('token') token: string | undefined, @Res() res: Response) {
    const profile = await this.prisma.profile.findUnique({ where: { id }, select: { id: true, venueId: true, photoKey: true } });
    if (!profile?.photoKey) throw new NotFoundException('Photo not found');
    try {
      this.mediaAccess.assertToken(token, 'profile-photo', `${profile.id}:${profile.photoKey}`, profile.venueId ?? profile.id);
    } catch {
      throw new NotFoundException('Photo not found');
    }
    return streamPrivateImage(await this.images.getObject(profile.photoKey), res);
  }
}
