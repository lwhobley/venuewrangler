import { BadRequestException, Body, Controller, Logger, Optional, Post, Req, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { Throttle } from '@nestjs/throttler';
import { Role } from '@prisma/client';
import { IsBoolean, IsEmail, IsIn, IsOptional, IsString, Matches, MaxLength, MinLength } from 'class-validator';
import type { Request } from 'express';
import { createHash, pbkdf2, randomBytes, randomInt, timingSafeEqual } from 'crypto';
import { promisify } from 'util';
import { hashInviteToken } from '../common/invite-token';

const pbkdf2Async = promisify(pbkdf2);
import { AllowUnverifiedEmail, Public } from './public.decorator';
import { CurrentUser } from './current-user.decorator';
import type { AuthUser } from './auth.guard';
import { getClientIp } from '../common/http';
import { assertWithinSharedRateLimit } from '../common/rate-limit';
import { EmailService } from '../email/email.service';
import { PrismaService } from '../prisma/prisma.service';
import { runWithoutTenant } from '../prisma/tenant-context';
import { isActiveMembership } from '../common/membership';
import { AuthService } from './auth.service';
import { AuditService } from '../modules/audit/audit.service';

const TRIAL_DURATION_MS = 14 * 24 * 60 * 60 * 1000;
const EMAIL_CODE_TTL_MS = 24 * 60 * 60 * 1000;
const PASSWORD_RESET_TTL_MS = 60 * 60 * 1000;
const PASSWORD_ITERATIONS = 600_000;
// Applies to newly-set passwords (signup, change, reset). Sign-in keeps the
// DTO's lower MinLength(6) floor so existing users with a shorter legacy
// password are not locked out.
const MIN_NEW_PASSWORD_LENGTH = 8;
const PASSWORD_KEY_LENGTH = 32;
const PASSWORD_DIGEST = 'sha256';
// Keep the unknown-user path computationally indistinguishable from a normal
// password check. This is a fixed hash for a non-secret, impossible account.
const DUMMY_PASSWORD_SALT = 'not-a-real-user-salt';
const DUMMY_PASSWORD_HASH = 'fbe490be8a0cbd07dcd5c3ec11d5525f878fa649e84c17864ad9d3e016700f20';
const AUTH_RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const AUTH_RATE_LIMIT_MAX = 12;
const MAX_FAILED_SIGN_INS = 8;
const VERIFY_EMAIL_RATE_LIMIT_MAX = 10;

class PasswordAuthDto {
  @IsEmail()
  email!: string;

  @IsString()
  @IsOptional()
  @MaxLength(50)
  phone?: string;

  @IsString()
  @MinLength(6)
  @MaxLength(128)
  password!: string;

  @IsIn(['signIn', 'signUp'])
  flow!: 'signIn' | 'signUp';

  @IsString()
  @IsOptional()
  @MaxLength(120)
  fullName?: string;

  @IsString()
  @IsOptional()
  @MaxLength(60)
  firstName?: string;

  @IsString()
  @IsOptional()
  @MaxLength(60)
  lastName?: string;

  @IsString()
  @IsOptional()
  @MaxLength(128)
  inviteToken?: string;

  @IsBoolean()
  @IsOptional()
  termsAccepted?: boolean;
}

class ChangePasswordDto {
  @IsString()
  @IsOptional()
  @MaxLength(128)
  currentPassword?: string;

  @IsString()
  @MinLength(6)
  @MaxLength(128)
  newPassword!: string;
}

class VerifyEmailDto {
  @IsString()
  @Matches(/^\d{10}$/)
  code!: string;
}

class ConfirmAdoptionDto {
  @IsString()
  @MaxLength(64)
  profileId!: string;
}

class ForgotPasswordDto {
  @IsEmail()
  email!: string;
}

class LogoutDto {
  // The Expo push token registered for THIS device (see usePushNotifications).
  // Optional and unvalidated in shape beyond being a string — deleteMany
  // below matches it against profileId, so a wrong value simply deletes
  // nothing rather than something belonging to another profile.
  @IsString()
  @IsOptional()
  @MaxLength(500)
  pushToken?: string;
}

class ResetPasswordDto {
  @IsEmail()
  email!: string;

  @IsString()
  @Matches(/^\d{10}$/)
  code!: string;

  @IsString()
  @MinLength(6)
  @MaxLength(128)
  newPassword!: string;
}

@Controller('v1/auth')
export class AuthController {
  private readonly logger = new Logger(AuthController.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly email: EmailService,
    private readonly authService: AuthService,
    @Optional() private readonly audit?: AuditService,
  ) {}

  @Public()
  @Throttle({ auth: { ttl: 60_000, limit: 20 } })
  @Post('password')
  async password(@Req() request: Request, @Body() body: PasswordAuthDto) {
    const email = body.email.trim().toLowerCase();
    if (!email || !body.password) throw new BadRequestException('Enter your email and password.');
    await assertWithinSharedRateLimit(this.prisma, `auth:ip:${getClientIp(request)}`, AUTH_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
    if (body.flow !== 'signIn') {
      await assertWithinSharedRateLimit(this.prisma, `auth:email:${email}`, AUTH_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
    }

    const user = await this.prisma.user.findUnique({ where: { email }, include: { password: true } });
    if (body.flow === 'signIn') {
      const credential = user?.password;
      const passwordMatches = credential
        ? await this.authService.verifyPassword(body.password, credential.salt, credential.iterations, credential.passwordHash)
        : await this.authService.verifyPassword(body.password, DUMMY_PASSWORD_SALT, PASSWORD_ITERATIONS, DUMMY_PASSWORD_HASH);
      // Checked after running the KDF above (not before) so response timing
      // stays uniform regardless of lock state. A locked account is rejected
      // even on a correct password — recordFailedSignIn already sets
      // lockedUntil after MAX_FAILED_SIGN_INS failures, but nothing previously
      // consulted it, so the lockout had no effect at all. reset-password
      // remains the recovery path (it clears lockedUntil).
      const isLocked = Boolean(user?.lockedUntil && user.lockedUntil.getTime() > Date.now());
      if (!credential || !passwordMatches) {
        // Apply the account-level limiter only after password verification so
        // a valid credential can always clear an attacker-induced lockout.
        await assertWithinSharedRateLimit(this.prisma, `auth:email:${email}`, AUTH_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
        if (user && !isLocked) {
          await this.recordFailedSignIn(user.id);
        }
        void this.audit?.record({
          action: isLocked ? 'auth.login.blocked' : 'auth.login.failed',
          entityType: 'User',
          entityId: user?.id,
          summary: isLocked
            ? `Sign-in blocked for ${email}: account temporarily locked`
            : `Failed login attempt for ${email}`,
          ipAddress: getClientIp(request),
          userAgent: typeof request.headers['user-agent'] === 'string' ? request.headers['user-agent'] : undefined,
          metadata: { email, reason: isLocked ? 'account_locked' : 'invalid_credentials' },
        });
        throw new UnauthorizedException(
          isLocked
            ? 'Too many failed sign-in attempts. Try again later or reset your password.'
            : 'Invalid email or password.',
        );
      }
      if (user.failedSignInCount > 0 || user.lockedUntil) {
        await this.prisma.user.update({
          where: { id: user.id },
          data: { failedSignInCount: 0, lockedUntil: null },
        });
      }
      // Transparently upgrade hash strength on login when the stored iteration
      // count is below the current target.
      if (credential.iterations < PASSWORD_ITERATIONS) {
        try {
          const upgraded = await this.authService.hashPassword(body.password);
          await this.prisma.passwordCredential.update({
            where: { userId: user.id },
            data: { salt: upgraded.salt, passwordHash: upgraded.hash, iterations: PASSWORD_ITERATIONS },
          });
        } catch (err: any) {
          this.logger.warn(`Failed to upgrade password hash strength for user ${user.id}: ${err?.message ?? String(err)}`);
        }
      }
      const result = await this.issueSession(user.id, email, body.fullName, body.inviteToken, body.phone);
      void this.audit?.record({
        venueId: result.profile.venueId,
        actorProfileId: result.profile.id,
        actorName: result.profile.fullName,
        actorRole: result.profile.role,
        action: 'auth.login.success',
        entityType: 'User',
        entityId: user.id,
        summary: `User ${result.profile.fullName || email} signed in successfully`,
        ipAddress: getClientIp(request),
        userAgent: typeof request.headers['user-agent'] === 'string' ? request.headers['user-agent'] : undefined,
      });
      return result;
    }

    // Reject signup whenever an account already exists for this email (with or
    // without a password). Allowing signup to attach or overwrite credentials on
    // an existing User record would allow claiming passwordless/OAuth/invited
    // accounts without proving ownership.
    if (user) {
      throw new BadRequestException('Unable to create account with those details. Try signing in or resetting your password.');
    }
    // The DTO's MinLength(6) is a floor shared with sign-in (existing users may
    // have shorter legacy passwords); new passwords must meet the current bar.
    if (body.password.length < MIN_NEW_PASSWORD_LENGTH) {
      throw new BadRequestException(`Password must be at least ${MIN_NEW_PASSWORD_LENGTH} characters.`);
    }
    if (body.termsAccepted !== true) {
      throw new BadRequestException('Accept the Terms of Service and Privacy Policy to create an account.');
    }

    // Build the display name from fullName (legacy) or firstName + lastName.
    const resolvedFullName = body.fullName?.trim()
      || [body.firstName, body.lastName].filter(Boolean).join(' ').trim()
      || undefined;

    const phone = body.phone?.trim().replace(/[\s\-().+]/g, '') || undefined;

    // Possession of the long, single-use token delivered to this exact inbox
    // proves control of the invited email — but only for invites that are
    // NEVER handed back to a human in an API response (workforce.controller's
    // legacy-roster mint, which always leaves `code: null`). Manager-created
    // invites (app.controller's createInvite) always set `code` and return the
    // raw token/inviteUrl to the manager, who could forward it to someone
    // other than the invited address; auto-verifying those would let that
    // person claim the invited email without ever controlling the inbox.
    const emailInvite = body.inviteToken?.trim()
      ? await this.prisma.invite.findFirst({
          where: {
            tokenHash: hashInviteToken(body.inviteToken.trim()),
            email: { equals: email, mode: 'insensitive' },
            usedBy: null,
            expiresAt: { gt: new Date() },
            code: null,
          },
          select: { id: true },
        })
      : null;

    const result = await this.authService.hashPassword(body.password);
    let nextUserId: string;
    try {
      nextUserId = await this.prisma.$transaction(async (tx) => {
        const nextUser = await tx.user.create({
          data: {
            email,
            phone,
            termsAcceptedAt: new Date(),
            ...(emailInvite ? { emailVerifiedAt: new Date() } : {}),
          },
        });
        await tx.passwordCredential.create({
          data: {
            userId: nextUser.id,
            salt: result.salt,
            passwordHash: result.hash,
            iterations: PASSWORD_ITERATIONS,
          },
        });
        return nextUser.id;
      });
    } catch (error: any) {
      // Unique violation on email or userId: the concurrent signup won the race.
      if (error?.code === 'P2002') {
        throw new BadRequestException('Unable to create account with those details. Try signing in or resetting your password.');
      }
      throw error;
    }
    const sessionResult = await this.issueSession(nextUserId, email, resolvedFullName, body.inviteToken, body.phone);
    void this.audit?.record({
      venueId: sessionResult.profile.venueId,
      actorProfileId: sessionResult.profile.id,
      actorName: sessionResult.profile.fullName,
      actorRole: sessionResult.profile.role,
      action: 'auth.signup.success',
      entityType: 'User',
      entityId: nextUserId,
      summary: `User ${sessionResult.profile.fullName || email} registered account`,
      ipAddress: getClientIp(request),
      userAgent: typeof request.headers['user-agent'] === 'string' ? request.headers['user-agent'] : undefined,
    });
    // Swallow delivery errors: the account is already created and the session
    // token is ready to return. The user can request a new code from the
    // verify-email screen if the email didn't arrive.
    let verificationEmailSent = !emailInvite ? false : null;
    if (!emailInvite) {
      try {
        await this.sendVerificationEmail(nextUserId, email, sessionResult.profile.fullName);
        verificationEmailSent = true;
      } catch (err: any) {
        // Identify by user id, never the address. Cloud Run logs are retained
        // and fan out to downstream sinks, so an email here is PII at rest for
        // the life of the log. The reset path below and the invite-check path
        // in workforce.controller already log this way.
        this.logger.error(`Verification email failed for user ${nextUserId}: ${err?.message ?? String(err)}`);
      }
    }
    // The failure is still swallowed — the account exists and the session token
    // is ready, so failing the signup would be worse. But it is reported now:
    // the app used to tell people to check an inbox for a code that was never
    // sent, with no way to tell that from a slow delivery.
    return { ...sessionResult, verificationEmailSent };
  }

  // Authenticated (not @Public): the global AuthGuard requires a valid bearer
  // token. Lets a signed-in user rotate their password; also lets a user who
  // signed up via OAuth set one for the first time.
  @Post('change-password')
  async changePassword(@Req() request: Request, @CurrentUser() user: AuthUser, @Body() body: ChangePasswordDto) {
    await assertWithinSharedRateLimit(this.prisma, `change-password:${user.sub}`, AUTH_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
    if (body.newPassword.length < MIN_NEW_PASSWORD_LENGTH) {
      throw new BadRequestException(`Password must be at least ${MIN_NEW_PASSWORD_LENGTH} characters.`);
    }
    const existing = await this.prisma.passwordCredential.findUnique({ where: { userId: user.sub } });
    if (existing) {
      const ok = await this.authService.verifyPassword(body.currentPassword ?? '', existing.salt, existing.iterations, existing.passwordHash);
      if (!ok) throw new UnauthorizedException('Current password is incorrect.');
    }
    const next = await this.authService.hashPassword(body.newPassword);
    await this.prisma.passwordCredential.upsert({
      where: { userId: user.sub },
      update: { salt: next.salt, passwordHash: next.hash, iterations: PASSWORD_ITERATIONS },
      create: { userId: user.sub, salt: next.salt, passwordHash: next.hash, iterations: PASSWORD_ITERATIONS },
    });
    // Revoke every other session so a leaked/old token can't survive a password
    // change; the caller's current session (if any) stays valid.
    await this.prisma.session.deleteMany({
      where: { userId: user.sub, ...(user.sid ? { NOT: { id: user.sid } } : {}) },
    });
    const account = await this.prisma.user.findUnique({
      where: { id: user.sub },
      select: { email: true },
    });
    if (account?.email) {
      void this.email.send({
        to: account.email,
        subject: 'Security Alert: Your Venue Wrangler Password Has Been Changed',
        text:
          `Hi there,\n\n` +
          `Your Venue Wrangler account password was successfully changed.\n\n` +
          `If you did not make this change, please reset your password immediately in the app and contact our support team at support@venuewrangler.com to secure your account.\n\n` +
          `Questions? support@venuewrangler.com\n\n` +
          `— The Venue Wrangler Team`,
      });
    }
    void this.audit?.record({
      venueId: user.venueId,
      actorProfileId: user.profileId,
      actorName: user.name,
      action: 'auth.password.changed',
      entityType: 'User',
      entityId: user.sub,
      summary: `User password changed`,
      ipAddress: getClientIp(request),
      userAgent: typeof request.headers['user-agent'] === 'string' ? request.headers['user-agent'] : undefined,
    });
    return { ok: true };
  }

  @AllowUnverifiedEmail()
  @Post('verify-email/send')
  async resendVerification(@CurrentUser() user: AuthUser) {
    const account = await this.prisma.user.findUnique({
      where: { id: user.sub },
      select: { email: true, emailVerifiedAt: true },
    });
    if (!account?.email) throw new BadRequestException('No email address is available for this account.');
    if (account.emailVerifiedAt) return { ok: true, alreadyVerified: true };
    await assertWithinSharedRateLimit(this.prisma, `verify-email:${user.sub}`, 5, AUTH_RATE_LIMIT_WINDOW_MS);
    await this.sendVerificationEmail(user.sub, account.email, user.name);
    return { ok: true };
  }

  @AllowUnverifiedEmail()
  @Post('verify-email')
  async verifyEmail(@Req() request: Request, @CurrentUser() user: AuthUser, @Body() body: VerifyEmailDto) {
    await assertWithinSharedRateLimit(this.prisma, `verify-email:ip:${getClientIp(request)}`, VERIFY_EMAIL_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `verify-email:user:${user.sub}`, VERIFY_EMAIL_RATE_LIMIT_MAX, AUTH_RATE_LIMIT_WINDOW_MS);
    const account = await this.prisma.user.findUnique({
      where: { id: user.sub },
      select: { emailVerificationCodeHash: true, emailVerificationSentAt: true, emailVerifiedAt: true },
    });
    if (!account) throw new UnauthorizedException('Account not found.');
    if (account.emailVerifiedAt) return { ok: true, alreadyVerified: true };
    if (!account.emailVerificationCodeHash || !account.emailVerificationSentAt) {
      throw new BadRequestException('Request a new verification code and try again.');
    }
    if (account.emailVerificationSentAt.getTime() + EMAIL_CODE_TTL_MS < Date.now()) {
      throw new BadRequestException('That verification code has expired. Request a new code.');
    }
    if (!this.authService.oneTimeCodeHashesMatch(account.emailVerificationCodeHash, this.authService.hashOneTimeCode(body.code))) {
      throw new BadRequestException('That verification code is not valid.');
    }
    // Unscoped on purpose. This route is authenticated, so AuthGuard has bound
    // the caller's CURRENT venue — and both Profile and Invite are venue-scoped,
    // so a pending membership at a DIFFERENT venue was invisible here. The user
    // row still got emailVerifiedAt, and because verifyEmail short-circuits on
    // `alreadyVerified` there was no second chance: the invited membership could
    // never be activated, locking the user out of that venue permanently.
    // Every query below is already constrained by userId.
    await runWithoutTenant(() => this.prisma.$transaction(async (tx) => {
      await tx.user.update({
        where: { id: user.sub },
        data: {
          emailVerifiedAt: new Date(),
          emailVerificationCodeHash: null,
          emailVerificationSentAt: null,
        },
      });
      const pendingProfiles = await tx.profile.findMany({
        where: { userId: user.sub, membershipStatus: 'pending' },
        select: { id: true },
      });
      if (pendingProfiles.length > 0) {
        const reservedInvites = await tx.invite.findMany({
          where: { usedBy: { in: pendingProfiles.map((profile) => profile.id) } },
          select: { usedBy: true },
        });
        const invitedProfileIds = reservedInvites
          .map((invite) => invite.usedBy)
          .filter((profileId): profileId is string => Boolean(profileId));
        if (invitedProfileIds.length > 0) {
          await tx.profile.updateMany({
            where: {
              id: { in: invitedProfileIds },
              userId: user.sub,
              membershipStatus: 'pending',
            },
            data: { membershipStatus: 'active' },
          });
        }
      }
    }));
    return { ok: true };
  }

  @Public()
  @Throttle({ auth: { ttl: 60_000, limit: 20 } })
  @Post('forgot-password')
  async forgotPassword(@Req() request: Request, @Body() body: ForgotPasswordDto) {
    const email = body.email.trim().toLowerCase();
    await assertWithinSharedRateLimit(this.prisma, `forgot-password:ip:${getClientIp(request)}`, 8, AUTH_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `forgot-password:email:${email}`, 5, AUTH_RATE_LIMIT_WINDOW_MS);

    const account = await this.prisma.user.findUnique({
      where: { email },
      select: { id: true, email: true, profiles: { select: { fullName: true }, take: 1 } },
    });
    // Always generate/hash a code and always issue the same shaped UPDATE. For
    // an unknown address the impossible id matches zero rows, preventing the
    // account-existence timing oracle caused by skipping the database write.
    const code = this.authService.generateOneTimeCode();
    const sentAt = new Date();
    await this.prisma.user.updateMany({
      where: { id: account?.id ?? '__missing_password_reset_account__' },
      data: {
        passwordResetCodeHash: this.authService.hashOneTimeCode(code),
        passwordResetExpiresAt: new Date(sentAt.getTime() + PASSWORD_RESET_TTL_MS),
        passwordResetSentAt: sentAt,
      },
    });
    if (account?.email) {
      const accountEmail = account.email;
      queueMicrotask(() => {
        void this.email.send({
          to: accountEmail,
          subject: 'Reset Your Venue Wrangler Password',
          text:
            `Hi ${account.profiles?.[0]?.fullName ?? 'there'},\n\n` +
            `We received a request to reset the password for your Venue Wrangler account.\n\n` +
            `To complete your password reset, enter the following code when prompted in the app:\n\n` +
            `   ${code}\n\n` +
            `Note: This code is valid for 60 minutes. If you did not request a password reset, you can safely ignore this email — your account remains secure.\n\n` +
            `Questions? support@venuewrangler.com\n\n` +
            `— The Venue Wrangler Team`,
        }).catch((error: any) => {
          this.logger.error(`Password reset email failed for user ${account.id}: ${error?.message ?? String(error)}`);
        });
      });
    }
    return { ok: true };
  }

  @Public()
  @Throttle({ auth: { ttl: 60_000, limit: 20 } })
  @Post('reset-password')
  async resetPassword(@Req() request: Request, @Body() body: ResetPasswordDto) {
    const email = body.email.trim().toLowerCase();
    if (body.newPassword.length < MIN_NEW_PASSWORD_LENGTH) {
      throw new BadRequestException(`Password must be at least ${MIN_NEW_PASSWORD_LENGTH} characters.`);
    }
    await assertWithinSharedRateLimit(this.prisma, `reset-password:ip:${getClientIp(request)}`, 8, AUTH_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `reset-password:email:${email}`, 8, AUTH_RATE_LIMIT_WINDOW_MS);

    // Reject invalid requests before running the expensive password KDF. The
    // transaction below repeats this check while holding the account lock so
    // concurrent requests cannot redeem the same one-time code twice.
    const candidateCodeHash = this.authService.hashOneTimeCode(body.code);
    const candidateAccount = await this.prisma.user.findUnique({
      where: { email },
      select: { passwordResetCodeHash: true, passwordResetExpiresAt: true },
    });
    if (
      !candidateAccount?.passwordResetCodeHash ||
      !candidateAccount.passwordResetExpiresAt ||
      candidateAccount.passwordResetExpiresAt.getTime() < Date.now() ||
      !this.authService.oneTimeCodeHashesMatch(candidateAccount.passwordResetCodeHash, candidateCodeHash)
    ) {
      throw new BadRequestException('That password reset code is invalid or expired.');
    }

    const next = await this.authService.hashPassword(body.newPassword);
    await this.prisma.$transaction(async (tx) => {
      // Serialize attempts for this account and validate only after acquiring
      // the lock, so the same one-time code cannot win two concurrent resets.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`password-reset:${email}`}))`;
      const account = await tx.user.findUnique({
        where: { email },
        select: {
          id: true,
          passwordResetCodeHash: true,
          passwordResetExpiresAt: true,
        },
      });
      if (
        !account?.passwordResetCodeHash ||
        !account.passwordResetExpiresAt ||
        account.passwordResetExpiresAt.getTime() < Date.now() ||
        !this.authService.oneTimeCodeHashesMatch(account.passwordResetCodeHash, this.authService.hashOneTimeCode(body.code))
      ) {
        throw new BadRequestException('That password reset code is invalid or expired.');
      }

      await tx.passwordCredential.upsert({
        where: { userId: account.id },
        update: {
          salt: next.salt,
          passwordHash: next.hash,
          iterations: PASSWORD_ITERATIONS,
        },
        create: {
          userId: account.id,
          salt: next.salt,
          passwordHash: next.hash,
          iterations: PASSWORD_ITERATIONS,
        },
      });
      await tx.user.update({
        where: { id: account.id },
        data: {
          passwordResetCodeHash: null,
          passwordResetExpiresAt: null,
          passwordResetSentAt: null,
          failedSignInCount: 0,
          lockedUntil: null,
        },
      });
      await tx.session.deleteMany({ where: { userId: account.id } });
    });
    return { ok: true };
  }

  // Revoke the current session (this device). The bearer token stops working
  // immediately on the next request.
  @AllowUnverifiedEmail()
  @Post('logout')
  async logout(@CurrentUser() user: AuthUser, @Body() body?: LogoutDto, @Req() request?: Request) {
    if (user.sid) {
      const pushToken = body?.pushToken?.trim();
      await this.prisma.$transaction([
        this.prisma.session.deleteMany({ where: { id: user.sid } }),
        // Delete only THIS device's push token, not every token the profile
        // has ever registered — deleting all of them (the prior behaviour)
        // silently killed push delivery to the user's other signed-in devices
        // whenever any single device signed out. Without a token, leave push
        // registrations untouched; a genuinely stale token still gets
        // disabled automatically by the delivery-failure path in
        // notifications.service.ts.
        ...(user.profileId && pushToken
          ? [this.prisma.pushToken.deleteMany({ where: { profileId: user.profileId, token: pushToken } })]
          : []),
      ]);
      void this.audit?.record({
        venueId: user.venueId,
        actorProfileId: user.profileId,
        actorName: user.name,
        action: 'auth.logout',
        entityType: 'Session',
        entityId: user.sid,
        summary: `User logged out session ${user.sid}`,
        ipAddress: request ? getClientIp(request) : undefined,
        userAgent: typeof request?.headers?.['user-agent'] === 'string' ? request.headers['user-agent'] : undefined,
      });
    }
    return { ok: true };
  }

  // Explicit, user-initiated confirmation of a pendingAdoption candidate
  // returned by a login/signup response. Nothing changes until the person
  // actually confirms — see AuthService.confirmProfileAdoption for why this
  // can no longer happen automatically.
  @Post('confirm-adoption')
  async confirmAdoption(@Req() request: Request, @CurrentUser() user: AuthUser, @Body() body: ConfirmAdoptionDto) {
    await assertWithinSharedRateLimit(this.prisma, `confirm-adoption:${user.sub}`, 10, AUTH_RATE_LIMIT_WINDOW_MS);
    await assertWithinSharedRateLimit(this.prisma, `confirm-adoption:ip:${getClientIp(request)}`, 10, AUTH_RATE_LIMIT_WINDOW_MS);
    const profile = await this.authService.confirmProfileAdoption(user.sub, body.profileId);
    return { profile: mapProfile(profile, true), venue: profile.venue ? mapVenue(profile.venue) : null };
  }

  // Revoke every session for the account (all devices).
  @AllowUnverifiedEmail()
  @Post('logout-all')
  async logoutAll(@CurrentUser() user: AuthUser) {
    await this.prisma.$transaction([
      this.prisma.session.deleteMany({ where: { userId: user.sub } }),
      ...(user.profileId
        ? [this.prisma.pushToken.deleteMany({ where: { profileId: user.profileId } })]
        : []),
    ]);
    return { ok: true };
  }

  private async issueSession(userId: string, email: string, fullName?: string, inviteToken?: string, rawPhone?: string) {
    const { session, profile, pendingAdoption } = await this.authService.issueSession(userId, email, fullName, inviteToken, rawPhone);
    const account = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { emailVerifiedAt: true },
    });
    const emailVerified = Boolean(account?.emailVerifiedAt);
    const token = await this.jwt.signAsync({
      sub: userId,
      email,
      name: profile.fullName,
      sid: session.id,
      profileId: profile.id,
      venueId: profile.venueId,
    });
    await this.prisma.session.update({
      where: { id: session.id },
      data: { tokenHash: createHash('sha256').update(token).digest('hex') },
    });
    const userProfiles =
      typeof this.prisma.profile?.findMany === 'function'
        ? await this.prisma.profile.findMany({
            where: {
              userId,
              venueId: { not: null },
              OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
            },
            include: { venue: { select: { id: true, name: true } } },
            orderBy: { createdAt: 'asc' },
          })
        : [];
    const venues = userProfiles
      .filter((p) => p.venue)
      .map((p) => ({
        id: p.venue!.id,
        name: p.venue!.name,
        role: p.role,
        profileId: p.id,
      }));

    return {
      token,
      profile: mapProfile(profile, emailVerified),
      venue: emailVerified && isActiveMembership(profile.membershipStatus) && profile.venue ? mapVenue(profile.venue) : null,
      venues,
      // A roster row elsewhere matched this account's verified email. Not
      // applied automatically — the client should prompt ("You appear to be
      // on the roster at {venueName} as {role} — join?") and call
      // POST /v1/auth/confirm-adoption only if the person confirms.
      pendingAdoption: pendingAdoption ?? null,
    };
  }

  private async recordFailedSignIn(userId: string) {
    await this.prisma.$transaction(async (transaction) => {
      // Serialize failures for one account. A plain read/increment/write lets
      // concurrent password attempts overwrite one another and bypass lockout.
      await transaction.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`auth-failed-sign-in:${userId}`}))`;
      const current = await transaction.user.findUnique({
        where: { id: userId },
        select: { failedSignInCount: true, lockedUntil: true },
      });
      if (!current || (current.lockedUntil && current.lockedUntil.getTime() > Date.now())) return;

      const nextCount = (current.lockedUntil ? 0 : current.failedSignInCount) + 1;
      await transaction.user.update({
        where: { id: userId },
        data: {
          failedSignInCount: nextCount >= MAX_FAILED_SIGN_INS ? 0 : nextCount,
          lockedUntil: nextCount >= MAX_FAILED_SIGN_INS ? new Date(Date.now() + AUTH_RATE_LIMIT_WINDOW_MS) : null,
        },
      });
    });
  }

  private async sendVerificationEmail(userId: string, email: string, fullName?: string) {
    const code = this.authService.generateOneTimeCode();
    await this.prisma.user.update({
      where: { id: userId },
      data: {
        emailVerificationCodeHash: this.authService.hashOneTimeCode(code),
        emailVerificationSentAt: new Date(),
      },
    });
    await this.email.sendOrThrow({
      to: email,
      subject: 'Verify Your Venue Wrangler Email Address',
      text:
        `Hi ${fullName?.trim() || 'there'},\n\n` +
        `Thank you for signing up for Venue Wrangler!\n\n` +
        `To complete your registration and verify your email address, please enter the following verification code in the app:\n\n` +
        `   ${code}\n\n` +
        `Note: This verification code is valid for 24 hours.\n\n` +
        `Questions? support@venuewrangler.com\n\n` +
        `— The Venue Wrangler Team`,
    });
  }
}


function mapVenue(venue: { id: string; name: string; latitude: number; longitude: number; geofenceRadiusM: number; timezone?: string | null }) {
  return {
    _id: venue.id,
    id: venue.id,
    name: venue.name,
    latitude: venue.latitude,
    longitude: venue.longitude,
    geofenceRadiusM: venue.geofenceRadiusM,
    geofence_radius_m: venue.geofenceRadiusM,
    timezone: venue.timezone ?? null,
  };
}

function mapProfile(profile: {
  id: string;
  email: string;
  fullName: string;
  role: Role;
  jobTitle: string;
  venueId: string | null;
  allAccess: boolean;
  membershipStatus?: string | null;
  trialEndsAt?: Date | null;
  phone?: string | null;
  altPhone?: string | null;
  address?: string | null;
  dateOfBirth?: Date | null;
  certifications?: string[];
}, emailVerified: boolean) {
  return {
    _id: profile.id,
    id: profile.id,
    email: profile.email,
    fullName: profile.fullName,
    full_name: profile.fullName,
    role: profile.role,
    jobTitle: profile.jobTitle,
    job_title: profile.jobTitle,
    venueId: profile.venueId,
    venue_id: profile.venueId,
    membershipStatus: profile.membershipStatus ?? null,
    allAccess: profile.allAccess,
    all_access: profile.allAccess,
    emailVerified,
    email_verified: emailVerified,
    trialEndsAt: profile.trialEndsAt?.getTime() ?? null,
    phone: profile.phone ?? null,
    altPhone: profile.altPhone ?? null,
    address: profile.address ?? null,
    dateOfBirth: profile.dateOfBirth?.toISOString() ?? null,
    certifications: profile.certifications ?? [],
  };
}
