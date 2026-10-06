import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHmac, timingSafeEqual } from 'crypto';

export type MediaKind = 'chat-image' | 'checklist-photo';

/** Duration of one time bucket in seconds (1 minute). */
const BUCKET_SECONDS = 60;

/**
 * Opaque, time-bucketed HMAC tokens for media access.
 *
 * React Native <Image> cannot send a bearer header, so image routes accept a
 * short-lived query-string token instead. Unlike the prior JWT approach, the
 * token is an opaque hex HMAC — no structured claims leak into logs,
 * screenshots, or shared links.
 *
 * Each token is valid for the current 1-minute time bucket plus the previous
 * one (to handle requests near a bucket boundary), giving an effective window
 * of 1–2 minutes.
 *
 * Prefer MEDIA_TOKEN_SECRET so media tokens can be rotated independently of
 * session JWTs. JWT_SECRET remains a compatible fallback.
 */
@Injectable()
export class MediaAccessService {
  private readonly secret: string;

  constructor(config: ConfigService) {
    const secret =
      config.get<string>('MEDIA_TOKEN_SECRET')?.trim() ||
      config.get<string>('JWT_SECRET')?.trim();
    if (!secret) {
      throw new Error('MEDIA_TOKEN_SECRET or JWT_SECRET is required for media access tokens');
    }
    this.secret = secret;
  }

  createPath(kind: MediaKind, mediaId: string, venueId: string, path: string, profileId?: string): string {
    const bucket = currentBucket();
    const token = this.computeHmac(kind, mediaId, venueId, bucket, profileId);
    const profileParam = profileId ? `&p=${encodeURIComponent(profileId)}` : '';
    return `${path}?token=${token}&t=${bucket}${profileParam}`;
  }

  assertToken(token: unknown, kind: MediaKind, mediaId: string, venueId: string, profileId?: string): void {
    if (typeof token !== 'string' || !token) throw new UnauthorizedException('Media access token is required');

    const now = currentBucket();

    // Accept current bucket or the immediately previous one (boundary grace).
    for (const bucket of [now, now - 1]) {
      const expected = this.computeHmac(kind, mediaId, venueId, bucket, profileId);
      if (safeCompare(token, expected)) return;
      // Fallback: if caller provided profileId but token was generated without it
      if (profileId) {
        const expectedWithoutProfile = this.computeHmac(kind, mediaId, venueId, bucket);
        if (safeCompare(token, expectedWithoutProfile)) return;
      }
    }

    throw new UnauthorizedException('Media access token is invalid or expired');
  }

  private computeHmac(kind: string, mediaId: string, venueId: string, bucket: number, profileId?: string): string {
    const profileSuffix = profileId ? `|${profileId}` : '';
    return createHmac('sha256', this.secret)
      .update(`media-access|${kind}|${mediaId}|${venueId}|${bucket}${profileSuffix}`)
      .digest('hex');
  }
}

function currentBucket(nowMs = Date.now()): number {
  return Math.floor(nowMs / 1000 / BUCKET_SECONDS);
}

function safeCompare(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8'));
}
