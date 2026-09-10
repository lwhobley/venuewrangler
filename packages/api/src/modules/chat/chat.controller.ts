import { streamPrivateImage } from '../../common/stream-private-image';
import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Delete,
  ForbiddenException,
  Get,
  Header,
  NotFoundException,
  Param,
  Post,
  Patch,
  Query,
  Res,
  StreamableFile,
} from '@nestjs/common';
import type { Response } from 'express';
import { ArrayMaxSize, IsArray, IsIn, IsOptional, IsString, MaxLength } from 'class-validator';
import { canManageVenue } from '../../auth/roles';
import { RequireSubscription } from '../../billing/require-subscription.decorator';
import { Public } from '../../auth/public.decorator';
import { SkipVenueScope } from '../../venue/skip-venue-scope.decorator';
import { canAccessConversation } from '../../common/conversation-access';
import { ALLOWED_IMAGE_MIME, assertAllowedImageBytes } from '../../common/image-bytes';
import { addDays, todayInZone, weekStartFor } from '../../common/pay-period';
import { occupiedSlots, previousOvernightFilter } from '../../common/shift-overlap';
import { tryAcquireSharedLease, releaseSharedLease } from '../../common/shared-lease';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { withSerializableRetry } from '../../common/tx-retry';
import { PrismaService } from '../../prisma/prisma.service';
import { VenueScope } from '../../venue/venue-scope.decorator';
import type { VenueScopedRequest } from '../../venue/venue-scope.interceptor';
import { MediaAccessService } from './media-access.service';
import { S3ImageService } from './s3-image.service';
import { MediaCleanupService } from '../media-cleanup/media-cleanup.service';
import { DocumentMalwareScannerService } from '../documents/document-malware-scanner.service';

// Chat photo uploads. Kept small — images are picker-compressed (quality 0.5)
// and clamped at 1280px on the device, typically ~300KB–1MB.
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

type Scope = VenueScopedRequest['venueScope'];

const GENERAL_GROUP_NAME = 'All Staff';
/** Keys per deletion job — keeps each `IN (...)` and objectKeys array well under Postgres's bind-parameter ceiling. */
const MEDIA_DELETION_BATCH_SIZE = 500;
const ACTIVE_MEMBERSHIP: Array<{ membershipStatus: null | 'active' }> = [
  { membershipStatus: null },
  { membershipStatus: 'active' },
];

class OpenDmDto {
  @IsString()
  @MaxLength(64)
  targetProfileId!: string;
}

class CreateGroupDto {
  @IsString()
  @MaxLength(100)
  name!: string;

  // Optional: the New group form asks for a name only, and the creator is
  // always added below, so a required array made every group creation fail
  // with a raw "memberIds must be an array" in front of the manager. People are
  // added to the group after it exists.
  @IsArray()
  @ArrayMaxSize(500)
  @IsString({ each: true })
  @MaxLength(64, { each: true })
  @IsOptional()
  memberIds?: string[];
}

class SendMessageDto {
  @IsString()
  @MaxLength(4000)
  text!: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  shiftId?: string;

  @IsString()
  @IsOptional()
  @MaxLength(64)
  swapId?: string;

  @IsString()
  @IsOptional()
  @MaxLength(2048)
  imageUrl?: string;
}

class ReactDto {
  @IsString()
  @MaxLength(32)
  emoji!: string;
}

class EditMessageDto {
  @IsString()
  @MaxLength(4000)
  text!: string;
}

class UploadImageDto {
  // Base64-encoded image bytes (no data: prefix), as produced by expo-image-picker.
  @IsString()
  @MaxLength(10_000_000)
  dataBase64!: string;

  @IsString()
  @IsIn(ALLOWED_IMAGE_MIME)
  mimeType!: string;
}

function requireManager(scope: Scope): asserts scope is NonNullable<Scope> {
  if (!scope || !canManageVenue(scope.role, scope.allAccess)) throw new ForbiddenException('Not authorized');
}

@Controller('v1/chat')
export class ChatController {
  // Postgres-backed lease keeps role/crew synchronization bounded across all replicas.
  private static readonly CONTEXTUAL_SYNC_THROTTLE_MS = 5 * 60 * 1000;

  constructor(
    private readonly prisma: PrismaService,
    private readonly mediaAccess: MediaAccessService,
    private readonly s3ImageService: S3ImageService,
    private readonly mediaCleanup: MediaCleanupService,
    private readonly malwareScanner: DocumentMalwareScannerService,
  ) {}

  private async ensureContextualConversationsThrottled(venueId: string) {
    const leaseKey = `chat-context:${venueId}`;
    const acquired = await tryAcquireSharedLease(
      this.prisma,
      leaseKey,
      ChatController.CONTEXTUAL_SYNC_THROTTLE_MS,
    );
    if (!acquired) {
      return;
    }
    try {
      await this.ensureContextualConversations(venueId);
    } catch (error) {
      // Release the lease so the next request on any replica retries immediately
      // instead of waiting for the full TTL to expire.
      await releaseSharedLease(this.prisma, leaseKey).catch(() => undefined);
      throw error;
    }
  }

  async ensureContextualConversations(venueId: string) {
    // --- Read phase (no transaction lock) ---
    // The shared lease already serializes concurrent syncs for this venue,
    // so the snapshot is stable without a transactional read lock.
    const venue = this.prisma.venue?.findUnique
      ? await this.prisma.venue.findUnique({ where: { id: venueId }, select: { timezone: true } })
      : null;
    const weekStart = venue ? weekStartFor(todayInZone(venue.timezone)) : undefined;
    const [profiles, allShifts, existingConvs] = await Promise.all([
      this.prisma.profile.findMany({
        where: { venueId, OR: ACTIVE_MEMBERSHIP },
        select: { id: true, jobTitle: true, role: true, allAccess: true },
      }),
      this.prisma.scheduleShift.findMany({
        where: weekStart
          ? {
              venueId,
              OR: [
                { weekStart },
                { ...previousOvernightFilter(weekStart, 0), endMinutes: { gt: 1440 } },
              ],
            }
          : { venueId },
        select: { profileId: true, weekStart: true, dayIndex: true, startMinutes: true, endMinutes: true },
      }),
      this.prisma.conversation.findMany({
        where: { venueId, type: { in: ['role', 'shift'] } },
      }),
    ]);

    // --- Compute diff in memory ---
    const managerIds = profiles.filter((p) => canManageVenue(p.role, p.allAccess)).map((p) => p.id);

    const existingRolesMap = new Map(existingConvs.filter((c) => c.type === 'role' && c.roleName).map((c) => [c.roleName!, c]));
    const existingShiftsMap = new Map(existingConvs.filter((c) => c.type === 'shift' && c.shiftDate).map((c) => [c.shiftDate!, c]));

    type WriteOp = { action: 'create'; data: any } | { action: 'update'; where: any; data: any };
    const writes: WriteOp[] = [];

    // 1. Role channels
    const roles = Array.from(new Set(profiles.map((p) => p.jobTitle || p.role).filter(Boolean)));
    for (const role of roles) {
      const roleMemberIds = Array.from(new Set([
        ...managerIds,
        ...profiles.filter((p) => p.jobTitle === role || p.role === role).map((p) => p.id)
      ])).sort();

      const existing = existingRolesMap.get(role);
      const name = `#Role - ${role}`;
      if (!existing) {
        writes.push({ action: 'create', data: { venueId, type: 'role', roleName: role, name, memberIds: roleMemberIds, isSystem: true } });
      } else {
        const sortedExistingMembers = [...existing.memberIds].sort();
        if (!sameMembers(roleMemberIds, sortedExistingMembers) || existing.name !== name || !existing.isSystem) {
          writes.push({ action: 'update', where: { id: existing.id }, data: { memberIds: roleMemberIds, name, isSystem: true } });
        }
      }
    }

    // 2. Shift crew channels for the current week
    const dayLabels = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    const shiftsByDay = Array.from({ length: 7 }, () => [] as string[]);
    for (const s of allShifts) {
      if (!s.profileId) continue;
      for (const slot of occupiedSlots({ ...s, weekStart: s.weekStart ?? weekStart ?? null })) {
        if (weekStart && slot.weekStart && slot.weekStart !== weekStart) continue;
        shiftsByDay[slot.dayIndex].push(s.profileId);
      }
    }

    for (let dayIndex = 0; dayIndex < 7; dayIndex++) {
      if (!weekStart) continue;
      const dateStr = addDays(weekStart, dayIndex);
      const dayLabel = dayLabels[dayIndex];

      const crewMemberIds = Array.from(new Set([
        ...managerIds,
        ...shiftsByDay[dayIndex],
      ])).sort();

      if (crewMemberIds.length > 0) {
        const existing = existingShiftsMap.get(dateStr);
        const name = `#Crew - ${dayLabel} (${formatMonthDay(dateStr)})`;
        if (!existing) {
          writes.push({ action: 'create', data: { venueId, type: 'shift', shiftDate: dateStr, name, memberIds: crewMemberIds, isSystem: true } });
        } else {
          const sortedExistingMembers = [...existing.memberIds].sort();
          if (!sameMembers(crewMemberIds, sortedExistingMembers) || existing.name !== name || !existing.isSystem) {
            writes.push({ action: 'update', where: { id: existing.id }, data: { memberIds: crewMemberIds, name, isSystem: true } });
          }
        }
      }
    }

    // --- Write phase (transaction lock — writes only) ---
    if (writes.length > 0) {
      await this.prisma.$transaction(async (tx) => {
        for (const op of writes) {
          if (op.action === 'create') {
            await tx.conversation.create({ data: op.data });
          } else {
            await tx.conversation.update({ where: op.where, data: op.data });
          }
        }
      });
    }
  }

  @RequireSubscription('active')
  @Get('conversations')
  async listConversations(@VenueScope() scope: Scope) {
    if (!scope) return { groups: [], dms: [], roles: [], shifts: [] };

    // Automatically synchronize role & crew chats on list view (throttled).
    await this.ensureContextualConversationsThrottled(scope.venueId);

    const all = await this.prisma.conversation.findMany({
      where: { venueId: scope.venueId },
      orderBy: { lastMessageAt: 'desc' },
      // Bounded by roster size in practice (DMs are per staff pair, groups
      // per role/shift), but capped defensively — this list has no pagination
      // on the client.
      take: 500,
    });

    const staff = await this.prisma.profile.findMany({
      where: { venueId: scope.venueId, OR: ACTIVE_MEMBERSHIP },
      select: { id: true, fullName: true },
    });
    const nameById = new Map(staff.map((s) => [s.id, s.fullName]));

    const myReads = await this.prisma.conversationRead.findMany({
      where: { venueId: scope.venueId, profileId: scope.profileId },
    });
    const readAtByConvId = new Map(myReads.map((r) => [r.conversationId, r.readAt]));

    const mapConv = (c: typeof all[0]) => {
      const lastRead = readAtByConvId.get(c.id);
      const unread = c.lastMessageAt && (!lastRead || lastRead < c.lastMessageAt);
      return {
        _id: c.id,
        id: c.id,
        type: c.type,
        title: c.name ?? 'Group',
        lastMessageText: c.lastMessageText ?? null,
        lastMessageAt: c.lastMessageAt?.getTime() ?? null,
        unread: Boolean(unread),
      };
    };

    const groups = all
      .filter((c) => c.type === 'group' && canAccessConversation(c.memberIds, c.type, scope.profileId))
      .map(mapConv);

    const roles = all
      .filter((c) => c.type === 'role' && canAccessConversation(c.memberIds, c.type, scope.profileId))
      .map(mapConv);

    const shifts = all
      .filter((c) => c.type === 'shift' && canAccessConversation(c.memberIds, c.type, scope.profileId))
      .map(mapConv);

    const dms = all
      .filter((c) => c.type === 'dm' && c.memberIds.includes(scope.profileId))
      .map((c) => {
        const otherId = c.memberIds.find((id) => id !== scope.profileId);
        const lastRead = readAtByConvId.get(c.id);
        const unread = c.lastMessageAt && (!lastRead || lastRead < c.lastMessageAt);
        return {
          _id: c.id,
          id: c.id,
          type: 'dm' as const,
          title: (otherId && nameById.get(otherId)) || 'Direct message',
          lastMessageText: c.lastMessageText ?? null,
          lastMessageAt: c.lastMessageAt?.getTime() ?? null,
          unread: Boolean(unread),
        };
      })
      .sort((a, b) => (b.lastMessageAt ?? 0) - (a.lastMessageAt ?? 0));

    return { groups, dms, roles, shifts };
  }

  @RequireSubscription('active')
  @Get('directory')
  async listDirectory(@VenueScope() scope: Scope) {
    if (!scope) return [];
    const staff = await this.prisma.profile.findMany({
      where: { venueId: scope.venueId, id: { not: scope.profileId }, OR: ACTIVE_MEMBERSHIP },
      orderBy: { fullName: 'asc' },
    });
    return staff.map((s) => ({
      _id: s.id,
      id: s.id,
      fullName: s.fullName,
      role: s.role,
      jobTitle: s.jobTitle,
    }));
  }

  @RequireSubscription('active')
  @Post('setup')
  async ensureChatSetup(@VenueScope() scope: Scope) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    // Any active member can trigger this (not just managers): the payload
    // written is entirely derived from the current roster, never from
    // caller-supplied data, so there is nothing here for a non-manager to
    // manipulate — the same shape as the role/shift sync above, which is
    // also open to any member. What DOES need protection is the read-decide-
    // write sequence itself: without a lock, two concurrent calls (e.g. two
    // staff loading the app at once when #General doesn't exist yet, or
    // membership changing between two overlapping calls) can race on the
    // same row. The advisory lock below serializes that, matching the
    // pattern the role/shift sync already uses via its shared lease.
    return withSerializableRetry(this.prisma, async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`chat-setup:${scope.venueId}`}))`;

      const [systemConversation, activeProfiles] = await Promise.all([
        tx.conversation.findFirst({
          where: { venueId: scope.venueId, type: 'group', isSystem: true },
        }),
        tx.profile.findMany({
          where: { venueId: scope.venueId, OR: ACTIVE_MEMBERSHIP },
          select: { id: true },
        }),
      ]);
      const existing = systemConversation ?? await tx.conversation.findFirst({
        where: { venueId: scope.venueId, type: 'group', name: GENERAL_GROUP_NAME },
      });
      const memberIds = Array.from(new Set([scope.profileId, ...activeProfiles.map((profile) => profile.id)])).sort();

      if (existing) {
        const existingMembers = [...existing.memberIds].sort();
        if (!sameMembers(existingMembers, memberIds) || existing.name !== GENERAL_GROUP_NAME || !existing.isSystem) {
          await tx.conversation.update({
            where: { id: existing.id },
            data: { name: GENERAL_GROUP_NAME, memberIds, isSystem: true },
          });
        }
        return { conversationId: existing.id };
      }

      try {
        const conv = await tx.conversation.create({
          data: {
            venueId: scope.venueId,
            type: 'group',
            name: GENERAL_GROUP_NAME,
            memberIds,
            isSystem: true,
          },
        });
        return { conversationId: conv.id };
      } catch (error: any) {
        // Defense in depth: the advisory lock above should make this
        // unreachable for two calls going through this same method, but keep
        // the fallback for any other path that could still insert the
        // isSystem row (e.g. a future migration/backfill).
        if (error?.code !== 'P2002') throw error;
        const winner = await tx.conversation.findFirst({
          where: { venueId: scope.venueId, type: 'group', isSystem: true },
        });
        if (!winner) throw error;
        await tx.conversation.update({
          where: { id: winner.id },
          data: { name: GENERAL_GROUP_NAME, memberIds, isSystem: true },
        });
        return { conversationId: winner.id };
      }
    });
  }

  @RequireSubscription('active')
  @Post('dm')
  async openDm(@VenueScope() scope: Scope, @Body() body: OpenDmDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    if (body.targetProfileId === scope.profileId) {
      throw new BadRequestException('You cannot start a direct message with yourself');
    }
    const other = await this.prisma.profile.findFirst({
      where: { id: body.targetProfileId, venueId: scope.venueId, OR: ACTIVE_MEMBERSHIP },
    });
    if (!other) throw new BadRequestException('User is not an active member of this venue');

    const pairKey = [scope.profileId, body.targetProfileId].sort().join(':');
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`chat-dm:${scope.venueId}:${pairKey}`}))`;
      const existing = await tx.conversation.findFirst({
        where: {
          venueId: scope.venueId,
          type: 'dm',
          memberIds: { hasEvery: [scope.profileId, body.targetProfileId] },
        },
      });
      if (existing) return { conversationId: existing.id };

      const conv = await tx.conversation.create({
        data: {
          venueId: scope.venueId,
          type: 'dm',
          memberIds: [scope.profileId, body.targetProfileId],
        },
      });
      return { conversationId: conv.id };
    });
  }

  @RequireSubscription('active')
  @Post('group')
  async createGroup(@VenueScope() scope: Scope, @Body() body: CreateGroupDto) {
    requireManager(scope);

    const name = body.name.trim();
    if (!name) throw new BadRequestException('Enter a group name');
    if (name.length > 100) throw new BadRequestException('Group name must be 100 characters or fewer');

    const memberIds = Array.from(new Set([scope.profileId, ...(body.memberIds ?? [])]));
    const activeMembers = await this.prisma.profile.findMany({
      where: { id: { in: memberIds }, venueId: scope.venueId, OR: ACTIVE_MEMBERSHIP },
      select: { id: true },
    });
    if (activeMembers.length !== memberIds.length) {
      throw new BadRequestException('All members must be active profiles in this venue');
    }
    const conv = await this.prisma.conversation.create({
      data: {
        venueId: scope.venueId,
        type: 'group',
        name,
        memberIds,
      },
    });

    return { conversationId: conv.id };
  }

  @RequireSubscription('active')
  @Delete('conversations/:id')
  async deleteConversation(@VenueScope() scope: Scope, @Param('id') id: string) {
    requireManager(scope);

    const conv = await this.prisma.conversation.findFirst({
      where: { id, venueId: scope.venueId },
    });
    if (!conv) throw new NotFoundException('Conversation not found');
    if (!canDeleteConversation(conv.type, conv.isSystem)) {
      throw new ForbiddenException('Only custom group chats can be deleted');
    }

    // Page inside the transaction. A long-lived group chat can hold thousands
    // of images; loading every key before deleting it is both unbounded and
    // can exceed Postgres's bind-parameter ceiling.
    const jobIds = await this.prisma.$transaction(async (tx) => {
      const created: string[] = [];
      for (;;) {
        const batch = await tx.chatImage.findMany({
          where: { message: { conversationId: id } },
          orderBy: { id: 'asc' },
          take: MEDIA_DELETION_BATCH_SIZE,
          select: { id: true, s3Key: true },
        });
        if (batch.length === 0) break;
        const job = await tx.objectDeletionJob.create({
          data: { objectKeys: batch.map((image) => image.s3Key) },
          select: { id: true },
        });
        created.push(job.id);
        await tx.chatImage.deleteMany({ where: { id: { in: batch.map((image) => image.id) } } });
      }
      await tx.message.deleteMany({ where: { conversationId: id } });
      await tx.conversation.delete({ where: { id: conv.id } });
      return created;
    }, {
      // A long-lived group chat pages through thousands of images here; the 5s
      // interactive default would abort mid-delete and roll the whole thing back.
      timeout: 120_000,
      maxWait: 10_000,
    });
    // Fire-and-forget a small bounded number. Awaiting serial S3 deletion
    // timed out the gateway for large conversations, while starting every job
    // at once can overload the shared bucket credential. The hourly cron is
    // the durable backstop for the remainder.
    for (const jobId of jobIds.slice(0, 5)) void this.mediaCleanup.processJob(jobId).catch(() => undefined);

    return { ok: true };
  }

  @RequireSubscription('active')
  @Get('conversations/:id/messages')
  async getMessages(
    @VenueScope() scope: Scope,
    @Param('id') id: string,
    // Pass the oldest message id already loaded to page further back in
    // history. Without this, history was hard-capped at the most recent 50
    // messages with no way to reach anything older through the API.
    @Query('before') before?: string,
  ) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    const conv = await this.prisma.conversation.findFirst({
      where: { id, venueId: scope.venueId },
    });
    if (!conv) throw new NotFoundException('Conversation not found');

    if (!canAccessConversation(conv.memberIds, conv.type, scope.profileId)) {
      throw new ForbiddenException('Not a participant');
    }

    const staff = await this.prisma.profile.findMany({
      where: { venueId: scope.venueId, OR: ACTIVE_MEMBERSHIP },
      select: { id: true, fullName: true },
    });
    const nameById = new Map(staff.map((s) => [s.id, s.fullName]));

    // Paging further back into history isn't "opening" the conversation, so
    // skip re-marking it read and skip recomputing title/read-receipts —
    // the client already has those from the initial load.
    let title: string | undefined;
    let readReceipts: { name: string; readAt: number }[] | undefined;
    if (!before) {
      title = conv.name ?? 'Chat';
      if (conv.type === 'dm') {
        const otherId = conv.memberIds.find((mid) => mid !== scope.profileId);
        title = (otherId && nameById.get(otherId)) || 'Direct message';
      }

      // Upsert read receipt for current user
      await this.prisma.conversationRead.upsert({
        where: {
          conversationId_profileId: {
            conversationId: id,
            profileId: scope.profileId,
          }
        },
        create: {
          conversationId: id,
          profileId: scope.profileId,
          venueId: scope.venueId,
          readAt: new Date(),
        },
        update: {
          readAt: new Date(),
        }
      });

      const reads = await this.prisma.conversationRead.findMany({
        where: { conversationId: id },
        select: { profileId: true, readAt: true },
      });

      readReceipts = reads
        .filter((r) => r.profileId !== scope.profileId)
        .map((r) => ({
          name: nameById.get(r.profileId) || 'Teammate',
          readAt: r.readAt.getTime(),
        }));
    }

    const PAGE_SIZE = 50;
    const recent = await this.prisma.message.findMany({
      where: { conversationId: id },
      orderBy: [{ createdAt: 'desc' }, { id: 'desc' }],
      // cursor + skip:1 walks strictly older than `before` in the same
      // (createdAt, id) order the initial page ended on — id is unique, so
      // this is stable even when multiple messages share a createdAt.
      ...(before ? { cursor: { id: before }, skip: 1 } : {}),
      take: PAGE_SIZE + 1,
    });
    const hasMore = recent.length > PAGE_SIZE;
    const messages = recent.slice(0, PAGE_SIZE).reverse();

    return {
      ...(title !== undefined ? { title } : {}),
      ...(readReceipts !== undefined ? { readReceipts } : {}),
      hasMore,
      messages: await Promise.all(messages.map(async (m) => {
        const imageId = m.imageUrl?.match(/^\/v1\/chat\/images\/([a-zA-Z0-9_-]+)$/)?.[1];
        return {
          _id: m.id,
          id: m.id,
          text: m.text,
          senderName: (m.senderId && nameById.get(m.senderId)) || 'Former teammate',
          createdAt: m.createdAt.getTime(),
          mine: m.senderId === scope.profileId,
          shiftId: m.shiftId,
          swapId: m.swapId,
          imageUrl: imageId
            ? await this.mediaAccess.createPath('chat-image', imageId, scope.venueId, m.imageUrl!)
            : m.imageUrl,
          reactions: m.reactions || {},
        };
      })),
    };
  }

  @RequireSubscription('active')
  @Post('conversations/:id/messages')
  async sendMessage(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: SendMessageDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    await assertWithinSharedRateLimit(
      this.prisma,
      `chat-send:profile:${scope.profileId}`,
      60,
      60_000,
      'Too many chat messages. Please wait a moment before sending again.',
    );

    const conv = await this.prisma.conversation.findFirst({
      where: { id, venueId: scope.venueId },
    });
    if (!conv) throw new NotFoundException('Conversation not found');

    if (!canAccessConversation(conv.memberIds, conv.type, scope.profileId)) {
      throw new ForbiddenException('Not a participant');
    }

    // Shift/swap references deep-link into venue-owned scheduling records, so
    // they must belong to this venue — otherwise a member could attach foreign
    // venue ids to messages.
    if (body.shiftId) {
      const shift = await this.prisma.scheduleShift.findFirst({
        where: { id: body.shiftId, venueId: scope.venueId },
        select: { id: true },
      });
      if (!shift) throw new BadRequestException('Shift not found in this venue');
    }
    if (body.swapId) {
      const swap = await this.prisma.shiftSwap.findFirst({
        where: { id: body.swapId, venueId: scope.venueId },
        select: { id: true },
      });
      if (!swap) throw new BadRequestException('Shift swap not found in this venue');
    }

    const text = body.text.trim();

    let imageUrl: string | null = null;
    let imageId: string | null = null;
    if (body.imageUrl) {
      const match = body.imageUrl.match(/\/v1\/chat\/images\/([a-zA-Z0-9_-]+)/);
      if (!match) {
        throw new BadRequestException('Invalid image URL format');
      }
      imageId = match[1];
      const image = await this.prisma.chatImage.findUnique({ where: { id: imageId } });
      if (!image || image.venueId !== scope.venueId || image.messageId || image.purgeStartedAt) {
        throw new BadRequestException('Image not found or does not belong to this venue');
      }
      imageUrl = `/v1/chat/images/${image.id}`;
    }

    if (!text && !imageUrl) throw new BadRequestException('Message text or image is required');

    const msg = await this.prisma.$transaction(async (transaction) => {
      // Lock the conversation so concurrent sends cannot commit an older
      // preview after a newer message. The message and preview then succeed or
      // roll back together.
      await transaction.$executeRaw`SELECT 1 FROM "Conversation" WHERE "id" = ${conv.id} FOR UPDATE`;
      const now = new Date();
      const created = await transaction.message.create({
        data: {
          conversationId: conv.id,
          venueId: conv.venueId,
          senderId: scope.profileId,
          text,
          shiftId: body.shiftId || null,
          swapId: body.swapId || null,
          imageUrl,
          createdAt: now,
        },
      });
      if (imageId) {
        const attached = await transaction.chatImage.updateMany({
          where: { id: imageId, venueId: scope.venueId, messageId: null, purgeStartedAt: null },
          data: { messageId: created.id },
        });
        if (attached.count !== 1) {
          throw new ConflictException('This image is no longer available. Upload it again.');
        }
      }
      await transaction.conversation.update({
        where: { id: conv.id },
        data: {
          lastMessageAt: now,
          lastMessageText: (text || '📷 Image').slice(0, 80),
        },
      });
      return created;
    });

    return { _id: msg.id, id: msg.id };
  }

  @RequireSubscription('active')
  @Post('messages/:id/react')
  async toggleReaction(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: ReactDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    const conv = await this.prisma.conversation.findFirst({
      where: { venueId: scope.venueId, messages: { some: { id } } },
    });
    if (!conv) throw new NotFoundException('Message not found');
    if (!canAccessConversation(conv.memberIds, conv.type, scope.profileId)) {
      throw new ForbiddenException('Not a participant');
    }

    // Read-modify-write on the reactions JSON column: retry on a lost race
    // (guarded by updatedAt) instead of silently dropping one user's toggle.
    const emoji = body.emoji;
    for (let attempt = 0; attempt < 5; attempt += 1) {
      const msg = await this.prisma.message.findFirst({ where: { id, venueId: scope.venueId } });
      if (!msg) throw new NotFoundException('Message not found');

      const reactions: Record<string, string[]> = Object.assign(
        Object.create(null),
        msg.reactions ?? {},
      );
      if (!Object.prototype.hasOwnProperty.call(reactions, emoji) && Object.keys(reactions).length >= 20) {
        throw new BadRequestException('A message can have at most 20 reaction types');
      }
      let users = reactions[emoji] || [];
      if (users.includes(scope.profileId)) {
        users = users.filter((uid) => uid !== scope.profileId);
      } else {
        users = [...users, scope.profileId];
      }
      if (users.length === 0) {
        delete reactions[emoji];
      } else {
        reactions[emoji] = users;
      }

      const updated = await this.prisma.message.updateMany({
        where: { id, updatedAt: msg.updatedAt },
        data: { reactions },
      });
      if (updated.count > 0) {
        return { ok: true, reactions };
      }
      // Someone else updated the row between our read and write — retry.
    }
    throw new ConflictException('This message changed while updating your reaction. Try again.');
  }

  @RequireSubscription('active')
  @Patch('messages/:id')
  async editMessage(@VenueScope() scope: Scope, @Param('id') id: string, @Body() body: EditMessageDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');
    const msg = await this.prisma.message.findFirst({ where: { id, venueId: scope.venueId } });
    if (!msg) throw new NotFoundException('Message not found');
    const conv = await this.prisma.conversation.findFirst({
      where: { id: msg.conversationId, venueId: scope.venueId },
    });
    if (!conv) throw new NotFoundException('Conversation not found');
    if (!canAccessConversation(conv.memberIds, conv.type, scope.profileId)) {
      throw new ForbiddenException('Not a participant');
    }
    if (msg.senderId !== scope.profileId) {
      throw new ForbiddenException('Only the sender can edit this message');
    }

    const text = body.text.trim();
    if (!text) throw new BadRequestException('Text is required');

    // The conversation list renders lastMessageText. Editing the newest message
    // left the old wording sitting in that preview, so the list and the thread
    // disagreed about what had been said. Only the newest message owns the
    // preview — editing an older one must not overwrite it.
    const newest = await this.prisma.message.findFirst({
      where: { conversationId: msg.conversationId, venueId: scope.venueId },
      orderBy: { createdAt: 'desc' },
      select: { id: true },
    });

    await this.prisma.$transaction([
      this.prisma.message.update({ where: { id }, data: { text } }),
      ...(newest?.id === id
        ? [
            this.prisma.conversation.update({
              where: { id: conv.id },
              data: { lastMessageText: text.slice(0, 80) },
            }),
          ]
        : []),
    ]);

    return { ok: true, text };
  }

  @RequireSubscription('active')
  @Post('images')
  async uploadImage(@VenueScope() scope: Scope, @Body() body: UploadImageDto) {
    if (!scope) throw new ForbiddenException('No venue profile found');

    const data = Buffer.from(body.dataBase64, 'base64');
    if (data.length === 0) throw new BadRequestException('Image is empty');
    if (data.length > MAX_IMAGE_BYTES) throw new BadRequestException('Image is too large (max 5MB)');
    const mime = assertAllowedImageBytes(data, body.mimeType);
    await this.malwareScanner.assertClean(data);

    const s3Key = await this.s3ImageService.upload(data, mime, scope.venueId);

    let image: { id: string };
    try {
      image = await this.prisma.chatImage.create({
        data: {
          venueId: scope.venueId,
          mimeType: mime,
          s3Key,
          uploadedBy: scope.profileId,
        },
        select: { id: true },
      });
    } catch (error) {
      await this.s3ImageService.delete(s3Key).catch(() => undefined);
      throw error;
    }

    // Relative path so the stored value stays portable across environments;
    // the client resolves it against its configured API base when rendering.
    const path = `/v1/chat/images/${image.id}`;
    return { imageUrl: await this.mediaAccess.createPath('chat-image', image.id, scope.venueId, path) };
  }

  // React Native <Image> cannot attach the app's bearer token, so this endpoint
  // accepts a short-lived token issued only in authenticated venue responses.
  @Public()
  @SkipVenueScope()
  @Get('images/:id')
  async getImage(@Param('id') id: string, @Query('token') token: string | undefined, @Res() res: Response) {
    const image = await this.prisma.chatImage.findUnique({ where: { id } });
    if (!image) throw new NotFoundException('Image not found');
    await this.mediaAccess.assertToken(token, 'chat-image', id, image.venueId);
    const object = await this.s3ImageService.getObject(image.s3Key);
    // Stream through the API origin already trusted by the web CSP. A redirect
    // would require allowing the private storage host as well.
    return streamPrivateImage(object, res);
  }
}

function canDeleteConversation(type: string, isSystem: boolean) {
  return type === 'group' && !isSystem;
}

function sameMembers(a: string[], b: string[]) {
  return a.length === b.length && a.every((id, index) => id === b[index]);
}

function formatMonthDay(isoDate: string) {
  return new Date(`${isoDate}T12:00:00Z`).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    timeZone: 'UTC',
  });
}
