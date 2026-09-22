import { BadRequestException, Body, Controller, Get, Logger, Post, ServiceUnavailableException, UseGuards } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SubscriptionStatus } from '@prisma/client';
import { IsIn, IsOptional, IsString, MaxLength } from 'class-validator';
import { AuthGuard } from '../../auth/auth.guard';
import { CurrentUser } from '../../auth/current-user.decorator';
import type { AuthUser } from '../../auth/auth.guard';
import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { stripeRequest } from '../../billing/stripe-api';
import { PrismaService } from '../../prisma/prisma.service';
import { publicWebOrigin } from '../../common/public-web-url';
import { toMs } from './app-mappers';
import { ProfileService } from './profile.service';
import { runWithoutTenant } from '../../prisma/tenant-context';
import { assertCoverageCapacity, COVERED_SUBSCRIPTION_DATA, effectiveSubscriptionStatus, isMultiVenuePlan } from '../../billing/billing-coverage';

// Idempotency key for the auto-created subscription price, so repeated lookups
// reuse one price instead of creating duplicates.
const STRIPE_PRICE_LOOKUP_KEY = 'venue_wrangler_monthly';
const STRIPE_MULTI_PRICE_LOOKUP_KEY = 'venue_wrangler_multi_venue_399';
const STRIPE_PLAN_AMOUNT_CENTS = 9999;
const STRIPE_MULTI_AMOUNT_CENTS = 39900;

class CreateStripeCheckoutDto {
  @IsString()
  @IsOptional()
  @IsIn(['single', 'multi_venue'])
  plan?: 'single' | 'multi_venue';
}

class AppleSubscriptionSyncDto {
  @IsString()
  @MaxLength(128)
  productId!: string;

  @IsString()
  @IsOptional()
  @MaxLength(128)
  entitlementId?: string;
}

// Billing read + Apple/RevenueCat entitlement sync for /v1/app/billing*.
// Split out of AppController; routes and response shapes are unchanged.
@Controller('v1/app')
export class AppBillingController {
  private readonly logger = new Logger(AppBillingController.name);
  // Resolved Stripe price ids are stable for the process; cache after first lookup.
  private cachedStripePriceId: string | null = null;
  private cachedStripeMultiVenuePriceId: string | null = null;

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
    private readonly profiles: ProfileService,
  ) {}

  @UseGuards(AuthGuard)
  @Get('billing')
  async getMyVenueBilling(@CurrentUser() user: AuthUser) {
    const profile = await this.profiles.getProfile(user);
    if (!profile?.venueId) return null;
    const allocation = await this.prisma.subscription.findFirst({ where: { venueId: profile.venueId }, include: { billingSubscription: true } });
    if (!allocation) return null;
    const subscription = allocation.billingSubscription ?? allocation;
    const status = allocation.billingSubscriptionId && (!allocation.billingSubscription || !isMultiVenuePlan(subscription))
      ? 'expired' : effectiveSubscriptionStatus(subscription);
    return {
      venueId: profile.venueId,
      billingVenueId: subscription.venueId,
      status,
      platform: subscription.platform,
      trialStartedAt: toMs(subscription.trialStartedAt),
      trialEndsAt: toMs(subscription.trialEndsAt),
      currentPeriodStart: toMs(subscription.currentPeriodStart),
      currentPeriodEnd: toMs(subscription.currentPeriodEnd),
      cancelAtPeriodEnd: subscription.cancelAtPeriodEnd,
      cancelledAt: toMs(subscription.cancelledAt),
      planId: subscription.planId,
      priceCents: subscription.priceCents,
      currency: subscription.currency,
    };
  }

  // Web subscribes through Stripe (Apple IAP only exists in the iOS app). The
  // session stamps venueId into metadata so the existing Stripe webhook
  // (BillingController) flips the same venue.subscriptionStatus to active —
  // which the iOS app then reads, so paid access is shared across platforms.
  @UseGuards(AuthGuard)
  @Post('billing/stripe/checkout')
  async createStripeCheckout(@CurrentUser() user: AuthUser, @Body() body?: CreateStripeCheckoutDto) {
    await assertWithinSharedRateLimit(this.prisma, `stripe-checkout:${user.sub}`, 10, 60_000);
    const profile = await this.profiles.requireBillingProfile(user);
    const secret = this.requireStripeSecret();
    const existing = await this.prisma.subscription.findFirst({
      where: { venueId: profile.venueId! },
      select: { status: true, platform: true, externalCustomerId: true, billingSubscriptionId: true },
    });
    if (existing?.billingSubscriptionId || existing?.platform === 'apple') {
      throw new BadRequestException('This venue already has a billing allocation. Manage its existing subscription first.');
    }
    if (existing?.platform === 'stripe' && (existing.status === 'active' || existing.status === 'trialing')) {
      throw new BadRequestException('This venue already has an active Stripe subscription.');
    }
    const isMulti = body?.plan === 'multi_venue';
    const priceId = await this.resolveStripePriceId(secret, isMulti ? 'multi_venue' : 'single');
    const base = this.webBaseUrl();
    const idempotencyKey = `checkout:${profile.venueId}:${isMulti ? 'multi' : 'single'}:${Math.floor(Date.now() / (10 * 60 * 1000))}`;
    const session = await stripeRequest<{ url?: string }>(secret, 'POST', '/checkout/sessions', {
      mode: 'subscription',
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${base}/billing?status=success`,
      cancel_url: `${base}/billing?status=cancelled`,
      client_reference_id: profile.venueId,
      ...(existing?.externalCustomerId ? { customer: existing.externalCustomerId } : {}),
      allow_promotion_codes: true,
      metadata: { venueId: profile.venueId, planType: isMulti ? 'multi_venue' : 'single' },
      subscription_data: { metadata: { venueId: profile.venueId, planType: isMulti ? 'multi_venue' : 'single' } },
    }, idempotencyKey);
    if (!session.url) {
      throw new ServiceUnavailableException('Stripe did not return a checkout URL.');
    }
    return { url: session.url };
  }

  // Stripe-billed venues manage/cancel through the Stripe customer portal (web
  // has no Apple subscriptions page). Apple-billed venues store the venueId as
  // their externalCustomerId, so we gate on platform === 'stripe'.
  @UseGuards(AuthGuard)
  @Post('billing/stripe/portal')
  async createStripePortal(@CurrentUser() user: AuthUser) {
    await assertWithinSharedRateLimit(this.prisma, `stripe-portal:${user.sub}`, 10, 60_000);
    const profile = await this.profiles.requireBillingProfile(user);
    const subscription = await this.prisma.subscription.findFirst({
      where: { venueId: profile.venueId! },
      select: { platform: true, externalCustomerId: true },
    });
    if (subscription?.platform !== 'stripe' || !subscription.externalCustomerId) {
      throw new BadRequestException('No Stripe subscription for this venue yet.');
    }
    const secret = this.requireStripeSecret();
    const base = this.webBaseUrl();
    const session = await stripeRequest<{ url?: string }>(secret, 'POST', '/billing_portal/sessions', {
      customer: subscription.externalCustomerId,
      return_url: `${base}/billing`,
    });
    if (!session.url) {
      throw new ServiceUnavailableException('Stripe did not return a portal URL.');
    }
    return { url: session.url };
  }

  private requireStripeSecret(): string {
    const secret = this.config.get<string>('STRIPE_SECRET_KEY');
    if (!secret) throw new ServiceUnavailableException('Stripe integration is not configured on the server.');
    return secret;
  }

  private webBaseUrl(): string {
    return publicWebOrigin(this.config);
  }

  private async resolveStripePriceId(secret: string, planType: 'single' | 'multi_venue' = 'single'): Promise<string> {
    if (planType === 'single') {
      const configured = this.config.get<string>('STRIPE_PRICE_ID');
      if (configured) return configured;
      if (this.cachedStripePriceId) return this.cachedStripePriceId;
    } else {
      const configuredMulti = this.config.get<string>('STRIPE_MULTI_VENUE_PRICE_ID');
      if (configuredMulti) return configuredMulti;
      if (this.cachedStripeMultiVenuePriceId) return this.cachedStripeMultiVenuePriceId;
    }

    // Never mint Stripe Products/Prices from a customer checkout request in
    // production: if an operator archives the current price in the Stripe
    // dashboard to change pricing, this lookup-then-create path would just
    // recreate a new price at the hardcoded amount below, silently reverting
    // the change (and leaving an orphaned Product behind on retry). Require
    // the price id to be configured explicitly instead.
    if (process.env.NODE_ENV === 'production') {
      const envKey = planType === 'multi_venue' ? 'STRIPE_MULTI_VENUE_PRICE_ID' : 'STRIPE_PRICE_ID';
      throw new ServiceUnavailableException(`${envKey} is not configured on the server.`);
    }

    const lookupKey = planType === 'multi_venue' ? STRIPE_MULTI_PRICE_LOOKUP_KEY : STRIPE_PRICE_LOOKUP_KEY;
    const amountCents = planType === 'multi_venue' ? STRIPE_MULTI_AMOUNT_CENTS : STRIPE_PLAN_AMOUNT_CENTS;
    const productName = planType === 'multi_venue' ? 'Venue Wrangler Multi-Venue Pro' : 'Venue Wrangler';

    this.logger.warn(`STRIPE_PRICE_ID for ${planType} is not configured; resolving/creating price at request time.`);
    const found = await stripeRequest<{ data?: { id: string }[] }>(secret, 'GET', '/prices', {
      lookup_keys: [lookupKey],
      active: true,
      limit: 1,
    });
    const existing = found.data?.[0]?.id;
    if (existing) {
      if (planType === 'multi_venue') this.cachedStripeMultiVenuePriceId = existing;
      else this.cachedStripePriceId = existing;
      return existing;
    }

    const product = await stripeRequest<{ id: string }>(secret, 'POST', '/products', { name: productName });
    try {
      const price = await stripeRequest<{ id: string }>(secret, 'POST', '/prices', {
        product: product.id,
        unit_amount: amountCents,
        currency: 'usd',
        recurring: { interval: 'month' },
        lookup_key: lookupKey,
      });
      if (planType === 'multi_venue') this.cachedStripeMultiVenuePriceId = price.id;
      else this.cachedStripePriceId = price.id;
      return price.id;
    } catch (error) {
      this.logger.warn(`Stripe price creation failed, attempting re-fetch: ${error instanceof Error ? error.message : String(error)}`);
      const retry = await stripeRequest<{ data?: { id: string }[] }>(secret, 'GET', '/prices', {
        lookup_keys: [lookupKey],
        active: true,
        limit: 1,
      });
      const claimed = retry.data?.[0]?.id;
      if (claimed) {
        if (planType === 'multi_venue') this.cachedStripeMultiVenuePriceId = claimed;
        else this.cachedStripePriceId = claimed;
        return claimed;
      }
      throw error;
    }
  }

  @UseGuards(AuthGuard)
  @Post('billing/apple/sync')
  async syncAppleSubscription(@CurrentUser() user: AuthUser, @Body() body: AppleSubscriptionSyncDto) {
    await assertWithinSharedRateLimit(this.prisma, `apple-sync:${user.sub}`, 10, 60_000);

    const profile = await this.profiles.requireBillingProfile(user);
    this.assertAllowedAppleSync(body.productId, body.entitlementId);
    const verified = await this.verifyRevenueCatEntitlement(user.sub, profile.venueId!, body.productId, body.entitlementId);
    if (!verified) {
      return this.getMyVenueBilling(user);
    }
    const status: SubscriptionStatus = 'active';
    const now = new Date();
    const isMulti = verified.productId === 'com.venuewrangler.multivenue.399';
    const priceCents = isMulti ? 39900 : 9999;
    const planId = isMulti ? 'venueflow_multi_venue_5' : verified.productId;

    await runWithoutTenant(() => this.prisma.$transaction(async (tx) => {
      // Serialize all allocations for this verified RevenueCat identity, not
      // only the selected venue. SDK aliases share original_app_user_id.
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`rc:${verified.subscriberId}`}))`;
      const bound = await tx.subscription.findUnique({ where: { revenueCatSubscriberId: verified.subscriberId } });
      const current = await tx.subscription.findFirst({ where: { venueId: profile.venueId! } });
      if (bound && bound.venueId !== profile.venueId && !isMulti) {
        throw new BadRequestException('This Apple subscription is already bound to another venue.');
      }
      const payerVenueId = bound?.venueId ?? profile.venueId!;
      if (payerVenueId !== profile.venueId) {
        const membership = await tx.profile.findFirst({ where: {
          userId: user.sub, venueId: payerVenueId, role: { in: ['owner', 'admin'] },
          OR: [{ membershipStatus: null }, { membershipStatus: 'active' }],
        } });
        if (!membership) throw new BadRequestException('You cannot manage the venue linked to this purchase.');
        if (!current || current.platform || current.externalSubscriptionId || current.revenueCatSubscriberId
            || (current.billingSubscriptionId && current.billingSubscriptionId !== bound!.id)) {
          throw new BadRequestException('This venue already has another billing allocation.');
        }
      }
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${payerVenueId}`}))`;
      const existing = await tx.subscription.findFirst({ where: { venueId: payerVenueId } });
      if (existing?.billingSubscriptionId || (existing?.platform && existing.platform !== 'apple')
          || (existing?.revenueCatSubscriberId && existing.revenueCatSubscriberId !== verified.subscriberId)) {
        throw new BadRequestException('This venue already has another billing allocation.');
      }
      // Legacy Apple rows without a canonical binding need an unambiguous
      // allocation. Do not let a fresh sync bypass a previous venue purchase.
      if (!bound) {
        const legacy = await tx.subscription.findMany({ where: {
          platform: 'apple', revenueCatSubscriberId: null, venueId: { not: payerVenueId },
          OR: [
            { externalCustomerId: { in: [user.sub, verified.subscriberId] } },
            { venue: { profiles: { some: { userId: user.sub, role: { in: ['owner', 'admin'] },
              OR: [{ membershipStatus: null }, { membershipStatus: 'active' }] } } } },
          ],
        }, take: 1, select: { id: true } });
        if (legacy.length) throw new BadRequestException('An existing Apple purchase needs to be linked from its original venue first.');
      }
      // A webhook received after the lookup started is newer than this snapshot.
      if (existing?.lastRevenueCatEventAt && existing.lastRevenueCatEventAt > verified.verifiedAt) return;
      const data = {
        status, platform: 'apple' as const, planId, priceCents,
        currentPeriodStart: verified.currentPeriodStart ?? existing?.currentPeriodStart ?? now,
        currentPeriodEnd: verified.currentPeriodEnd,
        cancelAtPeriodEnd: verified.cancelAtPeriodEnd, cancelledAt: null,
        externalCustomerId: user.sub, revenueCatSubscriberId: verified.subscriberId,
        lastRevenueCatEventAt: verified.verifiedAt,
      };
      const payer = existing
        ? await tx.subscription.update({ where: { id: existing.id }, data })
        : await tx.subscription.create({ data: {
            ...data, venueId: payerVenueId, currency: 'USD', trialStartedAt: null, trialEndsAt: null,
          } });
      await tx.venue.update({ where: { id: payerVenueId }, data: { subscriptionStatus: status, subscriptionPlatform: 'apple' } });
      if (payerVenueId !== profile.venueId) {
        await assertCoverageCapacity(tx, payer.id, current!.id);
        await tx.subscription.update({ where: { id: current!.id }, data: {
          ...COVERED_SUBSCRIPTION_DATA, billingSubscriptionId: payer.id,
        } });
      }
    }));

    return this.getMyVenueBilling(user);
  }

  private assertAllowedAppleSync(productId: string, entitlementId?: string) {
    const allowedProducts = new Set(this.csvEnv('REVENUECAT_ALLOWED_PRODUCT_IDS', 'com.venuewrangler.monthly,com.venuewrangler.multivenue.399'));
    const allowedEntitlements = new Set(this.csvEnv('REVENUECAT_ALLOWED_ENTITLEMENTS', 'pro,multi_venue'));
    if (!allowedProducts.has(productId)) {
      throw new BadRequestException('That Apple subscription product is not allowed for this app.');
    }
    if (entitlementId && !allowedEntitlements.has(entitlementId)) {
      throw new BadRequestException('That RevenueCat entitlement is not allowed for this app.');
    }
  }

  private async verifyRevenueCatEntitlement(userId: string, venueId: string, productId: string, entitlementId?: string) {
    const verifiedAt = new Date();
    const apiKey = this.config.get<string>('REVENUECAT_API_KEY') ?? this.config.get<string>('REVENUECAT_SECRET_API_KEY');
    if (!apiKey) {
      throw new ServiceUnavailableException('Apple subscription verification is not configured. Please contact support.');
    }

    let response: Response | undefined;
    let json: any = null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      try {
        response = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`, {
          headers: {
            Authorization: `Bearer ${apiKey}`,
            Accept: 'application/json',
          },
          signal: AbortSignal.timeout(10000),
        });
        json = await response.json().catch(() => null);
        if (response.ok || (response.status >= 400 && response.status < 500)) {
          break;
        }
      } catch (error) {
        if (attempt === 2) throw error;
      }
      if (attempt < 2) {
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
    }
    if (!response || !response.ok) {
      this.logger.warn(`RevenueCat verification failed for venue ${venueId}: ${json?.message ?? response?.statusText ?? 'Unknown error'}`);
      throw new BadRequestException('Could not verify RevenueCat subscription.');
    }

    const subscriber = json?.subscriber ?? {};
    const entitlements = subscriber.entitlements ?? {};
    const subscriptions = subscriber.subscriptions ?? {};
    const allowedEntitlements = new Set(this.csvEnv('REVENUECAT_ALLOWED_ENTITLEMENTS', 'pro,multi_venue'));
    const requestedEntitlement = entitlementId ? entitlements[entitlementId] : undefined;
    if (requestedEntitlement && requestedEntitlement.product_identifier !== productId) {
      throw new BadRequestException('RevenueCat entitlement does not match the requested Apple subscription product.');
    }
    const matchingEntitlement = entitlementId
      ? requestedEntitlement
      : Object.entries(entitlements).find(([key, entitlement]: [string, any]) =>
          allowedEntitlements.has(key) && entitlement?.product_identifier === productId,
        )?.[1];
    const matchingSubscription = subscriptions[productId];
    const expiresAt = parseRevenueCatDate(matchingEntitlement?.expires_date ?? matchingSubscription?.expires_date);
    const purchasedAt = parseRevenueCatDate(matchingEntitlement?.purchase_date ?? matchingSubscription?.purchase_date);
    const isActive = Boolean(matchingEntitlement) && expiresAt && expiresAt.getTime() > Date.now();
    if (!isActive) {
      throw new BadRequestException('No active RevenueCat entitlement found for this Apple subscription.');
    }

    return {
      productId, currentPeriodStart: purchasedAt, currentPeriodEnd: expiresAt!, verifiedAt,
      subscriberId: typeof subscriber.original_app_user_id === 'string' && subscriber.original_app_user_id ? subscriber.original_app_user_id : userId,
      cancelAtPeriodEnd: Boolean(matchingSubscription?.unsubscribe_detected_at),
    };
  }

  private csvEnv(key: string, fallback: string): string[] {
    const raw = this.config.get<string>(key) ?? fallback;
    return raw
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean);
  }
}

function parseRevenueCatDate(value: unknown) {
  if (typeof value !== 'string' || !value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}
