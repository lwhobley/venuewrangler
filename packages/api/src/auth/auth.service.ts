import { Injectable, UnauthorizedException } from '@nestjs/common';
import { Prisma, Role } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { createHmac, pbkdf2, randomBytes, randomInt, timingSafeEqual } from 'crypto';
import { ConfigService } from '@nestjs/config';
import { promisify } from 'util';
import { hashInviteToken } from '../common/invite-token';

const pbkdf2Async = promisify(pbkdf2);
const TRIAL_DURATION_MS = 14 * 24 * 60 * 60 * 1000;
// A stolen mobile bearer token must not remain useful for a full week. The
// server-side Session row still supports immediate logout/revocation.
export const SESSION_DURATION_MS = 24 * 60 * 60 * 1000;
const PASSWORD_ITERATIONS = 600_000;
const PASSWORD_KEY_LENGTH = 32;
const PASSWORD_DIGEST = 'sha256';

@Injectable()
export class AuthService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly config?: ConfigService,
  ) {}

  async hashPassword(password: string) {
    const salt = randomBytes(16).toString('hex');
    const hashBuffer = (await pbkdf2Async(password, salt, PASSWORD_ITERATIONS, PASSWORD_KEY_LENGTH, PASSWORD_DIGEST)) as Buffer;
    return { salt, hash: hashBuffer.toString('hex') };
  }

  async verifyPassword(password: string, salt: string, iterations: number, hash: string) {
    const derived = (await pbkdf2Async(password, salt, iterations, PASSWORD_KEY_LENGTH, PASSWORD_DIGEST)) as Buffer;
    const expected = Buffer.from(hash, 'hex');
    return derived.length === expected.length && timingSafeEqual(derived, expected);
  }

  generateOneTimeCode() {
    return Array.from({ length: 10 }, () => randomInt(0, 10)).join('');
  }

  hashOneTimeCode(code: string) {
    const pepper = this.config?.get<string>('JWT_SECRET')?.trim() || process.env.JWT_SECRET || '';
    return createHmac('sha256', pepper).update(code.trim()).digest('hex');
  }

  /** Constant-time comparison of two one-time-code hashes (both fixed-length hex digests). */
  oneTimeCodeHashesMatch(a: string, b: string): boolean {
    const bufA = Buffer.from(a, 'hex');
    const bufB = Buffer.from(b, 'hex');
    return bufA.length === bufB.length && timingSafeEqual(bufA, bufB);
  }

  async issueSession(userId: string, email: string, fullName?: string, inviteToken?: string, rawPhone?: string) {
    const trialEndsAt = new Date(Date.now() + TRIAL_DURATION_MS);
    const account = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { emailVerifiedAt: true },
    });
    const emailVerified = Boolean(account?.emailVerifiedAt);

    const inviteValue = inviteToken?.trim();
    const invite = inviteValue
      ? await this.prisma.invite.findFirst({
          where: {
            OR: [{ tokenHash: hashInviteToken(inviteValue) }, { code: { equals: inviteValue, mode: 'insensitive' } }],
            usedBy: null,
            expiresAt: { gt: new Date() },
          },
        })
      : null;

    if (invite?.email && invite.email.toLowerCase() !== email) {
      throw new UnauthorizedException('This invite was sent to a different email address.');
    }
    const phone = rawPhone?.trim().replace(/[\s\-().+]/g, '') || undefined;
    if (!invite?.email && invite?.phone && invite.phone !== phone) {
      throw new UnauthorizedException('This invite was sent to a different mobile number.');
    }
    const trimmedFullName = fullName?.trim();
    let pendingAdoption: { profileId: string; venueId: string; venueName: string; role: Role } | null = null;
    const profile = await this.prisma.$transaction(async (tx) => {
      let activeInvite = invite;
      if (invite) {
        const claimed = await tx.invite.updateMany({
          where: { id: invite.id, usedBy: null },
          data: { usedBy: `pending:${userId}` },
        });
        if (claimed.count === 0) activeInvite = null;
      }

      const grant = activeInvite
        ? {
            venueId: activeInvite.venueId,
            role: activeInvite.role,
            jobTitle: activeInvite.jobTitle,
            // Possession of a shareable manager invite is not proof that the
            // account owns its email address. Reserve the single-use invite
            // now, but keep the venue membership inert until verifyEmail
            // activates it in the same transaction as emailVerifiedAt.
            membershipStatus: emailVerified ? 'active' as const : 'pending' as const,
          }
        : null;

      const existingProfileForVenue = grant?.venueId
        ? await tx.profile.findFirst({
            where: { userId, venueId: grant.venueId },
            include: { venue: true },
          })
        : null;

      const existingByUser =
        existingProfileForVenue ||
        (await tx.profile.findFirst({
          where: { userId },
          include: { venue: true },
          orderBy: { createdAt: 'asc' },
        }));

      let result;
      if (existingByUser && (!grant?.venueId || existingByUser.venueId === grant.venueId)) {
        // A matching unclaimed roster row is surfaced as pendingAdoption
        // rather than merged automatically — see findAdoptableProfile's
        // doc comment for why a bare email match is not enough proof to
        // silently bind an account to a venue.
        const adoptableProfile = await this.findAdoptableProfile(tx, emailVerified, email);
        if (adoptableProfile && (!existingByUser.venueId || existingByUser.venueId === adoptableProfile.venueId) && adoptableProfile.venue) {
          pendingAdoption = { profileId: adoptableProfile.id, venueId: adoptableProfile.venueId!, venueName: adoptableProfile.venue.name, role: adoptableProfile.role };
        }
        result = await tx.profile.update({
          where: { id: existingByUser.id },
          data: {
            email,
            ...(trimmedFullName ? { fullName: trimmedFullName } : {}),
            ...(grant ?? {}),
            ...(existingByUser.trialEndsAt ? {} : { trialEndsAt }),
          },
          include: { venue: true },
        });
      } else if (grant?.venueId) {
        // User belongs to another venue and is joining this venue via invite -> create new profile for this venue
        result = await tx.profile.create({
          data: {
            userId,
            email,
            fullName: trimmedFullName || existingByUser?.fullName || email.split('@')[0] || 'Team Member',
            role: grant.role,
            jobTitle: grant.jobTitle,
            venueId: grant.venueId,
            membershipStatus: grant.membershipStatus,
            trialEndsAt,
          },
          include: { venue: true },
        });
      } else {
        // grant is always null here (a truthy grant would have matched the
        // `grant?.venueId` branch above), so this is exclusively the plain
        // login/signup path with no invite token at all. A matching
        // unclaimed roster row is surfaced as pendingAdoption rather than
        // merged automatically — see findAdoptableProfile's doc comment.
        const adoptableProfile = await this.findAdoptableProfile(tx, emailVerified, email);
        if (adoptableProfile && adoptableProfile.venueId && adoptableProfile.venue) {
          pendingAdoption = { profileId: adoptableProfile.id, venueId: adoptableProfile.venueId, venueName: adoptableProfile.venue.name, role: adoptableProfile.role };
        }
        result = await tx.profile.create({
          data: {
            userId,
            email,
            fullName: trimmedFullName || email.split('@')[0] || 'Team Member',
            role: 'staff',
            jobTitle: 'Staff',
            venueId: undefined,
            trialEndsAt,
          },
          include: { venue: true },
        });
      }

      if (activeInvite) {
        await tx.invite.update({ where: { id: activeInvite.id }, data: { usedBy: result.id } });
      }
      return result;
    });

    // Keep the row unusable until AuthController replaces this random value
    // with the hash of the signed JWT. The non-null placeholder makes partial
    // session issuance fail closed without requiring the final token up front.
    const tokenHash = randomBytes(32).toString('hex');
    const session = await this.prisma.session.create({
      data: { userId, expiresAt: new Date(Date.now() + SESSION_DURATION_MS), tokenHash },
    });
    return { session, profile, pendingAdoption };
  }

  /**
   * A roster row with no owner (userId: null) whose email matches the
   * signing-in account, found by verified-email match alone. This used to be
   * adopted automatically — no invite token, no confirmation — on every
   * login where the account had no other qualifying profile. Because
   * `upsertVenueStaff` never requires an Invite row to add someone to the
   * roster, that meant a manager's typo, or an unrelated person who happens
   * to already control a matching (already-verified) email address, could be
   * silently bound to a venue's staff roster on their very next login,
   * anywhere in the system — no consent, no scoping to the venue they were
   * actually trying to reach. It is now only ever a candidate: the caller
   * must confirm via confirmProfileAdoption() before anything changes.
   */
  private async findAdoptableProfile(tx: Prisma.TransactionClient, emailVerified: boolean, email: string) {
    if (!emailVerified) return null;
    return tx.profile.findFirst({
      where: { userId: null, email: { equals: email, mode: 'insensitive' }, venueId: { not: null } },
      orderBy: { createdAt: 'asc' },
      include: { venue: true },
    });
  }

  /**
   * Explicit, user-initiated confirmation of a pendingAdoption candidate
   * surfaced by issueSession(). Re-validates the same conditions at the time
   * of confirmation (the roster row could have been claimed, deleted, or
   * reassigned in the meantime) rather than trusting the earlier snapshot.
   */
  async confirmProfileAdoption(userId: string, profileId: string) {
    const account = await this.prisma.user.findUnique({ where: { id: userId }, select: { email: true, emailVerifiedAt: true } });
    if (!account?.email || !account.emailVerifiedAt) {
      throw new UnauthorizedException('Verify your email address before joining a workplace this way.');
    }
    return this.prisma.$transaction(async (tx) => {
      const candidate = await tx.profile.findFirst({
        where: { id: profileId, userId: null, email: { equals: account.email!, mode: 'insensitive' }, venueId: { not: null } },
        include: { venue: true },
      });
      if (!candidate) {
        throw new UnauthorizedException('This workplace connection is no longer available. It may have already been claimed.');
      }
      const existingByUser = await tx.profile.findFirst({ where: { userId }, orderBy: { createdAt: 'asc' } });
      if (existingByUser && existingByUser.venueId && existingByUser.venueId !== candidate.venueId) {
        throw new UnauthorizedException('Your account already belongs to a different venue.');
      }
      if (existingByUser) {
        await tx.profile.delete({ where: { id: existingByUser.id } });
      }
      // 'active', not 'pending': AuthGuard only ever resolves a profile with
      // membershipStatus null or 'active' (see ACTIVE_MEMBERSHIP), and unlike
      // an invite grant — where 'pending' is later flipped to 'active' by
      // verifyEmail's Invite.usedBy linkage — nothing else in the system
      // would ever activate a row created here. The caller already has a
      // verified email (checked above) and just explicitly confirmed the
      // connection, which is strictly more proof of intent than the invite
      // flow requires, so there is no reason to leave it inert.
      const adopted = await tx.profile.update({
        where: { id: candidate.id },
        data: { userId, role: candidate.role, membershipStatus: 'active' },
        include: { venue: true },
      });
      await this.logProfileAdoption(tx, adopted);
      return adopted;
    });
  }

  /**
   * Adoption links a sign-in to a pre-existing venue-owned profile purely by
   * verified-email match — there's no invite-token confirmation on this path.
   * Record it so a manager reviewing the venue's audit log can catch a
   * mis-typed roster email or a mis-bind, rather than it happening silently.
   */
  private async logProfileAdoption(
    tx: Prisma.TransactionClient,
    profile: { id: string; fullName: string; role: Role; venueId: string | null },
  ) {
    if (!profile.venueId) return;
    await tx.auditLog.create({
      data: {
        venueId: profile.venueId,
        actorProfileId: null,
        actorName: profile.fullName,
        actorRole: profile.role,
        targetProfileId: profile.id,
        targetName: profile.fullName,
        targetRole: profile.role,
        entityType: 'profile',
        entityId: profile.id,
        action: 'profile_adopted',
        summary: `${profile.fullName} signed in and was linked to this venue by matching verified email.`,
      },
    });
  }
}
