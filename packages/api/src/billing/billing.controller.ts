import { Body, Controller, Headers, Logger, Post, Req, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SubscriptionStatus } from '@prisma/client';
import type { Request } from 'express';
import { Public } from '../auth/public.decorator';
import { getClientIp } from '../common/http';
import { assertWithinSharedRateLimit } from '../common/rate-limit';
import { secretsMatch, verifyStripeSignature } from '../common/webhook-auth';
import { PrismaService } from '../prisma/prisma.service';

type RevenueCatWebhookBody = {
  event?: {
    id?: string;
    type?: string;
    app_user_id?: string;
    original_app_user_id?: string;
    product_id?: string;
    entitlement_ids?: string[];
    transaction_id?: string;
    original_transaction_id?: string;
    expiration_at_ms?: number;
    purchased_at_ms?: number;
    event_timestamp_ms?: number;
  };
};

const ACTIVE_REVENUECAT_EVENTS = new Set([
  'INITIAL_PURCHASE',
  'RENEWAL',
  'UNCANCELLATION',
  'PRODUCT_CHANGE',
  'NON_RENEWING_PURCHASE',
]);

const INACTIVE_REVENUECAT_EVENTS: Record<string, SubscriptionStatus> = {
  BILLING_ISSUE: 'past_due',
  EXPIRATION: 'expired',
  SUBSCRIPTION_PAUSED: 'paused',
};
const WEBHOOK_RATE_LIMIT_WINDOW_MS = 60_000;
const WEBHOOK_RATE_LIMIT_MAX = 120;

type StripeEvent = {
  id?: string;
  type?: string;
  created?: number;
  data?: { object?: any };
};

// Stripe subscription.status -> our SubscriptionStatus.
const STRIPE_STATUS_MAP: Record<string, SubscriptionStatus> = {
  active: 'active',
  trialing: 'trialing',
  past_due: 'past_due',
  unpaid: 'past_due',
  canceled: 'cancelled',
  paused: 'paused',
  incomplete: 'past_due',
  incomplete_expired: 'expired',
};

type SubscriptionInput = {
  venueId: string;
  status: SubscriptionStatus;
  planId: string;
  priceCents?: number | null;
  currency?: string | null;
  externalSubscriptionId?: string | null;
  externalCustomerId?: string | null;
  currentPeriodStart?: Date | null;
  currentPeriodEnd?: Date | null;
  cancelAtPeriodEnd?: boolean;
  trialStartedAt?: Date | null;
  trialEndsAt?: Date | null;
  eventId?: string;
  eventType?: string;
  eventAt?: Date;
  payload?: unknown;
};

function unixToDate(seconds: number | null | undefined): Date | null {
  return typeof seconds === 'number' && Number.isFinite(seconds) ? new Date(seconds * 1000) : null;
}

@Controller('v1/billing')
export class BillingController {
  private readonly logger = new Logger(BillingController.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  @Public()
  @Post('revenuecat/webhook')
  async revenueCatWebhook(@Req() request: Request, @Headers('authorization') authorization: string | undefined, @Body() body: RevenueCatWebhookBody) {
    // Fail closed: the webhook is @Public(), so without a configured secret
    // anyone could forge subscription state for any venue. Always require it.
    // Authenticate before rate limiting so unauthenticated sprays cannot churn
    // RateLimitBucket rows (same ordering as POS ingest).
    const expectedSecret = this.config.get<string>('REVENUECAT_WEBHOOK_SECRET');
    if (!expectedSecret) {
      throw new UnauthorizedException('RevenueCat webhook secret is not configured');
    }
    const token = authorization?.replace(/^Bearer\s+/i, '').trim();
    if (!secretsMatch(token, expectedSecret)) {
      throw new UnauthorizedException('Invalid RevenueCat webhook secret');
    }
    await assertWithinSharedRateLimit(this.prisma, `revenuecat:${getClientIp(request)}`, WEBHOOK_RATE_LIMIT_MAX, WEBHOOK_RATE_LIMIT_WINDOW_MS, 'Too many webhook requests.');

    const event = body.event;
    // app_user_id is the account id passed to Purchases.configure/logIn
    // (see configurePurchases(userId) in app/_layout.tsx). Older clients sent
    // venueId. Trusted only after the Bearer secret check above. RevenueCat
    // "Transfer behavior" must stay "Do not transfer".
    const subscriberId = event?.app_user_id;
    if (!event?.type || !subscriberId) {
      return { ok: true, ignored: true };
    }
    // Only apply state for the product/entitlement this app actually sells.
    // Without this, any event RevenueCat delivers under the same account
    // (e.g. a different app's product) could flip a venue's status.
    if (!this.isAllowedRevenueCatEvent(event.product_id, event.entitlement_ids)) {
      return { ok: true, ignored: true };
    }

    const expiresInFuture = event.expiration_at_ms ? event.expiration_at_ms > Date.now() : false;
    const status = event.type === 'CANCELLATION' && expiresInFuture
      ? 'active'
      : event.type === 'CANCELLATION'
        ? 'cancelled'
        : ACTIVE_REVENUECAT_EVENTS.has(event.type)
      ? 'active'
      : INACTIVE_REVENUECAT_EVENTS[event.type];
    if (!status) {
      return { ok: true, ignored: true };
    }

    const venueIds = await this.resolveRevenueCatVenueIds(subscriberId, event.original_app_user_id, event.original_transaction_id);
    if (venueIds.length === 0) {
      return { ok: true, ignored: true };
    }

    for (const venueId of venueIds) {
      await this.applyAppleSubscription({
        venueId,
        status,
        planId: event.product_id ?? 'apple_subscription',
        externalSubscriptionId: event.original_transaction_id ?? null,
        externalCustomerId: subscriberId,
        currentPeriodStart: event.purchased_at_ms ? new Date(event.purchased_at_ms) : null,
        currentPeriodEnd: event.expiration_at_ms ? new Date(event.expiration_at_ms) : null,
        trialStartedAt: status === 'trialing' && event.purchased_at_ms ? new Date(event.purchased_at_ms) : null,
        trialEndsAt: status === 'trialing' && event.expiration_at_ms ? new Date(event.expiration_at_ms) : null,
        cancelAtPeriodEnd: event.type === 'CANCELLATION' && expiresInFuture,
        eventId: event.id ?? `${event.type}:${venueId}:${event.event_timestamp_ms ?? Date.now()}`,
        eventType: event.type,
        eventAt: new Date(event.event_timestamp_ms ?? event.purchased_at_ms ?? Date.now()),
        payload: body,
      });
    }

    return { ok: true };
  }

  @Public()
  @Post('stripe/webhook')
  async stripeWebhook(
    @Req() request: Request,
    @Headers('stripe-signature') signature: string | undefined,
    @Body() body: StripeEvent,
  ) {
    // Authenticate before rate limiting so unauthenticated sprays cannot churn
    // RateLimitBucket rows (same ordering as POS ingest).
    const secret = this.config.get<string>('STRIPE_WEBHOOK_SECRET');
    if (!secret) {
      throw new UnauthorizedException('Stripe webhook secret is not configured');
    }
    const rawBody = (request as unknown as { rawBody?: Buffer }).rawBody;
    if (!verifyStripeSignature(rawBody, signature, secret)) {
      throw new UnauthorizedException('Invalid Stripe signature');
    }
    await assertWithinSharedRateLimit(this.prisma, `stripe:${getClientIp(request)}`, WEBHOOK_RATE_LIMIT_MAX, WEBHOOK_RATE_LIMIT_WINDOW_MS, 'Too many webhook requests.');

    const event = body;
    const object = event.data?.object ?? {};
    const eventAt = unixToDate(event.created) ?? new Date();

    if (
      event.type === 'customer.subscription.created' ||
      event.type === 'customer.subscription.updated' ||
      event.type === 'customer.subscription.deleted'
    ) {
      const venueId = await this.resolveStripeVenueId(object);
      if (!venueId) return { ok: true, ignored: true };
      const status =
        event.type === 'customer.subscription.deleted'
          ? ('cancelled' as SubscriptionStatus)
          : STRIPE_STATUS_MAP[object.status] ?? null;
      if (!status) return { ok: true, ignored: true };
      const firstItem = object.items?.data?.[0] ?? {};
      const price = firstItem.price ?? {};
      // Stripe API 2025-03-31+ moved current_period_* from the subscription
      // object onto each item. Read from the item first; fall back to the
      // legacy top-level fields for older API versions.
      const periodStart = firstItem.current_period_start ?? object.current_period_start;
      const periodEnd = firstItem.current_period_end ?? object.current_period_end;
      await this.applyStripeSubscription({
        venueId,
        status,
        planId: typeof price.id === 'string' ? price.id : 'stripe_subscription',
        priceCents: typeof price.unit_amount === 'number' ? price.unit_amount : null,
        currency: typeof price.currency === 'string' ? price.currency.toUpperCase() : null,
        externalSubscriptionId: typeof object.id === 'string' ? object.id : null,
        externalCustomerId: typeof object.customer === 'string' ? object.customer : null,
        currentPeriodStart: unixToDate(periodStart),
        currentPeriodEnd: unixToDate(periodEnd),
        trialStartedAt: unixToDate(object.trial_start),
        trialEndsAt: unixToDate(object.trial_end),
        cancelAtPeriodEnd: Boolean(object.cancel_at_period_end),
        eventId: event.id,
        eventType: event.type,
        eventAt,
        payload: body,
      });
      return { ok: true };
    }

    if (event.type === 'invoice.payment_succeeded' || event.type === 'invoice.payment_failed') {
      await this.recordStripeInvoice(object, event, eventAt);
      return { ok: true };
    }

    if (event.type === 'charge.refunded') {
      await this.recordStripeRefund(object, event, eventAt);
      return { ok: true };
    }

    return { ok: true, ignored: true };
  }

  private isAllowedRevenueCatEvent(productId: string | undefined, entitlementIds: string[] | undefined): boolean {
    const allowedProducts = this.csvEnv('REVENUECAT_ALLOWED_PRODUCT_IDS', 'com.venuewrangler.monthly,com.venuewrangler.multivenue.399');
    const allowedEntitlements = this.csvEnv('REVENUECAT_ALLOWED_ENTITLEMENTS', 'pro,multi_venue');
    if (!productId && (!entitlementIds || entitlementIds.length === 0)) return false;
    if (productId && !allowedProducts.has(productId)) return false;
    if (entitlementIds && entitlementIds.length > 0 && !entitlementIds.some((id) => allowedEntitlements.has(id))) {
      return false;
    }
    return true;
  }

  private csvEnv(key: string, fallback: string): Set<string> {
    const raw = this.config.get<string>(key) ?? fallback;
    return new Set(raw.split(',').map((value) => value.trim()).filter(Boolean));
  }

  private async resolveStripeVenueId(object: any): Promise<string | null> {
    const metaVenueId = typeof object?.metadata?.venueId === 'string' ? object.metadata.venueId : null;
    const subId = typeof object?.id === 'string' ? object.id : null;
    const customerId = typeof object?.customer === 'string' ? object.customer : null;
    return this.resolveStripeVenueIdByRefs(metaVenueId, subId, customerId);
  }

  private async resolveStripeVenueIdByRefs(
    metaVenueId: string | null,
    subId: string | null,
    customerId: string | null,
  ): Promise<string | null> {
    if (typeof metaVenueId === 'string' && metaVenueId) {
      const venue = await this.prisma.venue.findUnique({ where: { id: metaVenueId }, select: { id: true } });
      if (venue) return venue.id;
    }
    if (!subId && !customerId) return null;
    const existing = await this.prisma.subscription.findFirst({
      where: {
        OR: [
          ...(subId ? [{ externalSubscriptionId: subId }] : []),
          ...(customerId ? [{ externalCustomerId: customerId }] : []),
        ],
      },
      select: { venueId: true },
    });
    return existing?.venueId ?? null;
  }

  private async recordStripeInvoice(invoice: any, event: StripeEvent, eventAt: Date) {
    const stripeInvoiceId = typeof invoice?.id === 'string' ? invoice.id : null;
    if (!stripeInvoiceId) return;
    // Stripe API 2025-03-31 removed the top-level `invoice.subscription` and
    // moved it under `parent.subscription_details`. The subscription handler
    // above already migrated `current_period_*` for the same version bump; this
    // one was missed. Read the new location first and keep the legacy field for
    // accounts still on an older API version.
    const nestedSubId = invoice?.parent?.subscription_details?.subscription;
    const subId = typeof nestedSubId === 'string'
      ? nestedSubId
      : typeof invoice?.subscription === 'string'
        ? invoice.subscription
        : null;
    const customerId = typeof invoice?.customer === 'string' ? invoice.customer : null;
    const venueId = await this.resolveStripeVenueIdByRefs(
      typeof invoice?.metadata?.venueId === 'string' ? invoice.metadata.venueId : null,
      subId,
      customerId,
    );
    if (!venueId) {
      // Previously a silent return: an invoice for a customer with no prior
      // Subscription row was dropped with no trace at all.
      this.logger.warn(
        `Stripe invoice ${stripeInvoiceId} (${event.type ?? 'unknown'}) could not be matched to a venue; ignoring.`,
      );
      return;
    }

    const data = {
      venueId,
      amountCents: Math.round(Number(invoice.amount_paid ?? invoice.amount_due ?? 0)) || 0,
      currency: String(invoice.currency ?? 'usd').toUpperCase(),
      status: String(invoice.status ?? 'open'),
      invoiceUrl: typeof invoice.invoice_pdf === 'string' ? invoice.invoice_pdf : null,
      hostedInvoiceUrl: typeof invoice.hosted_invoice_url === 'string' ? invoice.hosted_invoice_url : null,
      periodStart: unixToDate(invoice.period_start) ?? eventAt,
      periodEnd: unixToDate(invoice.period_end) ?? eventAt,
      paidAt: unixToDate(invoice.status_transitions?.paid_at),
    };
    try {
      await this.prisma.$transaction(async (tx) => {
        await tx.invoice.upsert({
          where: { stripeInvoiceId },
          create: { stripeInvoiceId, ...data },
          update: data,
        });
        await tx.subscriptionEvent.create({
          data: {
            venueId,
            source: 'stripe',
            externalEventId: event.id ?? `inv:${stripeInvoiceId}:${event.type}`,
            eventType: event.type ?? 'invoice',
            payload: event as never,
            processedAt: new Date(),
            status: 'processed',
          },
        });
      });
    } catch (error: any) {
      if (error?.code === 'P2002') return;
      throw error;
    }
  }

  private async recordStripeRefund(charge: any, event: StripeEvent, eventAt: Date) {
    const stripeInvoiceId = typeof charge?.invoice === 'string' ? charge.invoice : null;
    if (!stripeInvoiceId) return;

    const invoice = await this.prisma.invoice.findUnique({ where: { stripeInvoiceId } });
    const venueId =
      invoice?.venueId
      ?? await this.resolveStripeVenueIdByRefs(
        typeof charge?.metadata?.venueId === 'string' ? charge.metadata.venueId : null,
        null,
        typeof charge?.customer === 'string' ? charge.customer : null,
      );
    if (!venueId) return;

    try {
      await this.prisma.$transaction(async (tx) => {
        await tx.invoice.upsert({
          where: { stripeInvoiceId },
          create: {
            venueId,
            stripeInvoiceId,
            amountCents: 0,
            currency: String(charge?.currency ?? 'usd').toUpperCase(),
            status: charge.refunded ? 'refunded' : 'partially_refunded',
            invoiceUrl: null,
            hostedInvoiceUrl: null,
            periodStart: eventAt,
            periodEnd: eventAt,
            paidAt: null,
          },
          update: { status: charge.refunded ? 'refunded' : 'partially_refunded' },
        });
        await tx.subscriptionEvent.create({
          data: {
            venueId,
            source: 'stripe',
            externalEventId: event.id ?? `refund:${stripeInvoiceId}`,
            eventType: event.type ?? 'charge.refunded',
            payload: event as never,
            processedAt: new Date(),
            status: 'processed',
          },
        });
      });
    } catch (error: any) {
      if (error?.code === 'P2002') return;
      throw error;
    }
  }

  async applyStripeSubscription(input: SubscriptionInput) {
    return this.applySubscription({ ...input, platform: 'stripe', source: 'stripe', staleField: 'lastStripeEventAt' });
  }

  async applyAppleSubscription(input: SubscriptionInput) {
    return this.applySubscription({ ...input, platform: 'apple', source: 'revenuecat', staleField: 'lastRevenueCatEventAt' });
  }

  private async applySubscription(input: SubscriptionInput & {
    platform: 'stripe' | 'apple';
    source: string;
    staleField: 'lastStripeEventAt' | 'lastRevenueCatEventAt';
  }) {
    const now = new Date();
    const eventAt = input.eventAt ?? now;
    try {
      return await this.prisma.$transaction(async (tx) => {
        await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${`billing:${input.venueId}`}))`;
        const venue = await tx.venue.findUnique({ where: { id: input.venueId } });
        if (!venue) return null;

        const existing = await tx.subscription.findFirst({ where: { venueId: input.venueId } });
        const lastEventAt = existing?.[input.staleField];
        const isStale = Boolean(lastEventAt && lastEventAt > eventAt);
        if (isStale) {
          if (input.eventId && input.eventType) {
            await tx.subscriptionEvent.create({
              data: {
                venueId: input.venueId,
                source: input.source,
                externalEventId: input.eventId,
                eventType: input.eventType,
                payload: (input.payload ?? {}) as never,
                processedAt: now,
                status: 'ignored_stale',
              },
            });
          }
          return { status: existing!.status, ignored: true };
        }

        await tx.venue.update({
          where: { id: input.venueId },
          data: { subscriptionStatus: input.status, subscriptionPlatform: input.platform },
        });
        const eventTimestamp = { [input.staleField]: eventAt };
        if (existing) {
          await tx.subscription.update({
            where: { id: existing.id },
            data: {
              status: input.status,
              platform: input.platform,
              planId: input.planId,
              priceCents: input.priceCents ?? existing.priceCents,
              currency: input.currency ?? existing.currency,
              currentPeriodStart: input.currentPeriodStart ?? existing.currentPeriodStart,
              currentPeriodEnd: input.currentPeriodEnd ?? existing.currentPeriodEnd,
              cancelAtPeriodEnd: input.cancelAtPeriodEnd ?? false,
              cancelledAt: input.status === 'cancelled' ? now : input.status === 'active' ? null : existing.cancelledAt,
              externalSubscriptionId: input.externalSubscriptionId ?? existing.externalSubscriptionId,
              externalCustomerId: input.externalCustomerId ?? existing.externalCustomerId,
              trialStartedAt: input.trialStartedAt !== undefined ? input.trialStartedAt : existing.trialStartedAt,
              trialEndsAt: input.trialEndsAt !== undefined ? input.trialEndsAt : existing.trialEndsAt,
              ...eventTimestamp,
            },
          });
        } else {
          await tx.subscription.create({
            data: {
              venueId: input.venueId,
              status: input.status,
              platform: input.platform,
              planId: input.planId,
              priceCents: input.priceCents ?? 0,
              currency: input.currency ?? 'USD',
              // Only a genuinely trialing subscription has trial dates; a
              // subscription applied directly at another status (e.g. an
              // active Stripe/Apple event with no prior trial) has none —
              // stamping "now" for both would misrepresent it as a trial that
              // started and instantly expired.
              trialStartedAt: input.trialStartedAt !== undefined ? input.trialStartedAt : (input.status === 'trialing' ? now : null),
              trialEndsAt: input.trialEndsAt !== undefined ? input.trialEndsAt : (input.status === 'trialing' ? now : null),
              currentPeriodStart: input.currentPeriodStart ?? now,
              currentPeriodEnd: input.currentPeriodEnd,
              cancelAtPeriodEnd: input.cancelAtPeriodEnd ?? false,
              cancelledAt: input.status === 'cancelled' ? now : null,
              externalSubscriptionId: input.externalSubscriptionId ?? null,
              externalCustomerId: input.externalCustomerId ?? null,
              ...eventTimestamp,
            },
          });
                }
        if (input.eventId && input.eventType) {
          await tx.subscriptionEvent.create({
            data: {
              venueId: input.venueId,
              source: input.source,
              externalEventId: input.eventId,
              eventType: input.eventType,
              payload: (input.payload ?? {}) as never,
              processedAt: now,
              status: 'processed',
            },
          });
        }
        return { status: input.status };
      });
    } catch (error: any) {
      if (error?.code === 'P2002' && (error.meta?.target as string[] | undefined)?.includes('externalEventId')) {
        return { ok: true, duplicate: true };
      }
      throw error;
    }
  }

  private async resolveRevenueCatVenueIds(subscriberId: string, originalSubscriberId?: string, transactionId?: string): Promise<string[]> {
    // Resolve only a durable allocation, never every venue in a user's current
    // memberships. A webhook before the first authenticated sync is ignored;
    // sync reads the provider's current state and establishes the allocation.
    if (transactionId) {
      const transaction = await this.prisma.subscription.findUnique({
        where: { externalSubscriptionId: transactionId },
        select: { venueId: true, platform: true },
      });
      if (transaction?.platform === 'apple') return [transaction.venueId];
    }
    const ids = [...new Set([subscriberId, originalSubscriberId].filter((id): id is string => Boolean(id)))];
    const allocations = await this.prisma.subscription.findMany({
      where: { platform: 'apple', billingSubscriptionId: null, OR: [
        { revenueCatSubscriberId: { in: ids } },
        // Legacy webhook-bound rows remain usable only if unambiguous.
        { revenueCatSubscriberId: null, externalCustomerId: { in: ids } },
      ] },
      select: { venueId: true }, take: 2,
    });
    return allocations.length === 1 ? [allocations[0].venueId] : [];
  }
}
