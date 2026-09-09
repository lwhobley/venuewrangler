import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { PrismaClient } from '@prisma/client';
import { setupTestDb } from '../test/setup-test-db';
import { BillingController } from './billing.controller';
import type { PrismaService } from '../prisma/prisma.service';
import { COVERED_SUBSCRIPTION_DATA } from './billing-coverage';
import { resolveVenueSubscriptionStatus } from './subscription-status';

/**
 * Idempotency proof for the shared Stripe/RevenueCat subscription-apply path.
 * Duplicate webhook deliveries are a normal, expected occurrence for both
 * providers (at-least-once delivery); this proves a replayed event does not
 * double-process.
 *
 * The actual mechanism (billing.controller.ts applySubscription): a unique
 * constraint on SubscriptionEvent(source, externalEventId) + a P2002 catch
 * that returns `{ duplicate: true }` instead of re-applying. Critically, the
 * redundant venue/subscription update happens INSIDE the same transaction as
 * the duplicate-detecting insert, so when the insert fails on the second
 * delivery, Postgres rolls back the whole transaction — not just the audit
 * row. This spec verifies that rollback actually happens against real
 * Postgres, not just that the second call returns a "duplicate" flag.
 */
describe('billing webhook idempotency (integration)', () => {
  let prisma: PrismaClient;
  let teardown: () => Promise<void> = async () => {};
  let controller: BillingController;
  let venueId = '';

  beforeAll(async () => {
    const db = await setupTestDb();
    prisma = db.prisma;
    teardown = db.teardown;
    // ConfigService is only used by the HTTP webhook handlers (secret lookup),
    // not by applyStripeSubscription/applyAppleSubscription — a stub is fine.
    const configStub = { get: () => undefined } as any;
    controller = new BillingController(prisma as unknown as PrismaService, configStub);
  });

  beforeEach(async () => {
    const venue = await prisma.venue.create({
      data: {
        name: 'Idempotency Test Venue',
        code: `VW-${randomUUID().replaceAll('-', '').slice(0, 12).toUpperCase()}`,
        latitude: 0,
        longitude: 0,
        geofenceRadiusM: 100,
        timezone: 'UTC',
      },
    });
    venueId = venue.id;
  });

  afterAll(async () => {
    if (!prisma) return;
    await prisma.subscriptionEvent.deleteMany();
    await prisma.subscription.deleteMany();
    await prisma.venue.deleteMany();
    await teardown();
  });

  it('a replayed Stripe event is a no-op: exactly one SubscriptionEvent row, unchanged subscription state', async () => {
    const eventAt = new Date();
    const payload = {
      venueId,
      status: 'active' as const,
      planId: 'price_test123',
      priceCents: 4900,
      currency: 'USD',
      externalSubscriptionId: 'sub_test123',
      externalCustomerId: 'cus_test123',
      eventId: 'evt_replayed_test',
      eventType: 'customer.subscription.created',
      eventAt,
    };

    const first = await controller.applyStripeSubscription(payload);
    expect(first).toMatchObject({ status: 'active' });

    const afterFirst = await prisma.subscription.findFirst({ where: { venueId } });
    expect(afterFirst?.status).toBe('active');

    // Replay the exact same event (same eventId, same eventAt) — simulates
    // Stripe's at-least-once delivery re-sending the same webhook.
    const second = await controller.applyStripeSubscription(payload);
    expect(second).toMatchObject({ ok: true, duplicate: true });

    const events = await prisma.subscriptionEvent.findMany({
      where: { venueId, source: 'stripe', externalEventId: 'evt_replayed_test' },
    });
    expect(events).toHaveLength(1);

    const afterSecond = await prisma.subscription.findFirst({ where: { venueId } });
    expect(afterSecond?.status).toBe('active');
    expect(afterSecond?.updatedAt.getTime()).toBe(afterFirst?.updatedAt.getTime());
  });

  it('processes one Apple event for a payer and resolves cancellation for every covered venue', async () => {
    const payer = await prisma.subscription.create({ data: {
      venueId, status: 'active', platform: 'apple', planId: 'com.venuewrangler.multivenue.399',
      priceCents: 39900, currency: 'USD', cancelAtPeriodEnd: false,
      revenueCatSubscriberId: 'rc-covered-customer', externalSubscriptionId: 'apple-covered-transaction',
      currentPeriodEnd: new Date('2030-01-01'),
    } });
    const coveredVenueIds: string[] = [];
    for (let i = 0; i < 4; i++) {
      const venue = await prisma.venue.create({ data: {
        name: `Covered ${i}`, code: `VW-${randomUUID()}`, latitude: 1, longitude: 1, geofenceRadiusM: 100, timezone: 'UTC',
      } });
      coveredVenueIds.push(venue.id);
      await prisma.subscription.create({ data: {
        ...COVERED_SUBSCRIPTION_DATA, venueId: venue.id, billingSubscriptionId: payer.id,
        planId: 'venueflow_multi_venue_5', priceCents: 39900, currency: 'USD',
      } });
    }
    for (const id of coveredVenueIds) {
      expect(await resolveVenueSubscriptionStatus(prisma as any, { venueId: id, venueStatus: 'expired' })).toBe('active');
    }
    const extra = await prisma.venue.create({ data: {
      name: 'Sixth venue', code: `VW-${randomUUID()}`, latitude: 1, longitude: 1, geofenceRadiusM: 100, timezone: 'UTC',
    } });
    await expect(prisma.subscription.create({ data: {
      ...COVERED_SUBSCRIPTION_DATA, venueId: extra.id, billingSubscriptionId: payer.id,
      planId: 'venueflow_multi_venue_5', priceCents: 39900, currency: 'USD',
    } })).rejects.toThrow(/five venues/);
    await expect(prisma.subscription.create({ data: {
      venueId: extra.id, status: 'active', planId: 'single', priceCents: 9999, currency: 'USD', cancelAtPeriodEnd: false,
      revenueCatSubscriberId: 'rc-covered-customer',
    } })).rejects.toMatchObject({ code: 'P2002' });

    const webhook = new BillingController(prisma as any, {
      get: (key: string) => key === 'REVENUECAT_WEBHOOK_SECRET' ? 'integration-secret' : undefined,
    } as any);
    const body = { event: {
      id: 'evt-covered-cancellation', type: 'CANCELLATION', app_user_id: 'rc-covered-customer',
      original_transaction_id: 'apple-covered-transaction', product_id: 'com.venuewrangler.multivenue.399',
      entitlement_ids: ['multi_venue'], expiration_at_ms: Date.now() - 1000, event_timestamp_ms: Date.now(),
    } };
    await webhook.revenueCatWebhook({ ip: '127.0.0.1' } as any, 'Bearer integration-secret', body);
    await webhook.revenueCatWebhook({ ip: '127.0.0.1' } as any, 'Bearer integration-secret', body);
    expect(await prisma.subscriptionEvent.count({ where: { externalEventId: body.event.id } })).toBe(1);
    for (const id of coveredVenueIds) {
      expect(await resolveVenueSubscriptionStatus(prisma as any, { venueId: id, venueStatus: 'active' })).toBe('cancelled');
    }
    // Deleting the payer must fail closed, never revive the child trial.
    await prisma.subscription.delete({ where: { id: payer.id } });
    expect(await resolveVenueSubscriptionStatus(prisma as any, { venueId: coveredVenueIds[0], venueStatus: 'active' })).toBe('expired');
  });

  it('a replayed RevenueCat event is also a no-op', async () => {
    const eventAt = new Date();
    const payload = {
      venueId,
      status: 'active' as const,
      planId: 'apple_subscription',
      externalSubscriptionId: 'apple_txn_test456',
      externalCustomerId: venueId,
      eventId: 'evt_apple_replayed_test',
      eventType: 'INITIAL_PURCHASE',
      eventAt,
    };

    const first = await controller.applyAppleSubscription(payload);
    expect(first).toMatchObject({ status: 'active' });

    const second = await controller.applyAppleSubscription(payload);
    expect(second).toMatchObject({ ok: true, duplicate: true });

    const events = await prisma.subscriptionEvent.findMany({
      where: { venueId, source: 'revenuecat', externalEventId: 'evt_apple_replayed_test' },
    });
    expect(events).toHaveLength(1);
  });

  it('an out-of-order (stale) event is ignored without overwriting newer state', async () => {
    const now = new Date();
    const earlier = new Date(now.getTime() - 60_000);

    await controller.applyStripeSubscription({
      venueId,
      status: 'active',
      planId: 'price_test123',
      eventId: 'evt_current',
      eventType: 'customer.subscription.updated',
      eventAt: now,
    });

    // A late-arriving, older event (e.g. redelivered after a retry backlog)
    // must not roll the status back to what it was before the newer event.
    const stale = await controller.applyStripeSubscription({
      venueId,
      status: 'past_due',
      planId: 'price_test123',
      eventId: 'evt_stale',
      eventType: 'customer.subscription.updated',
      eventAt: earlier,
    });
    expect(stale).toMatchObject({ status: 'active', ignored: true });

    const afterStale = await prisma.subscription.findFirst({ where: { venueId } });
    expect(afterStale?.status).toBe('active');
  });
});
