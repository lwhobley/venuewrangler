import { UnauthorizedException } from '@nestjs/common';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { assertWithinSharedRateLimit } from '../common/rate-limit';
import { verifyStripeSignature } from '../common/webhook-auth';
import { BillingController } from './billing.controller';

vi.mock('../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('../common/webhook-auth', async () => {
  const actual = await vi.importActual<typeof import('../common/webhook-auth')>('../common/webhook-auth');
  return {
    ...actual,
    verifyStripeSignature: vi.fn(),
  };
});

describe('BillingController webhook authentication', () => {
  beforeEach(() => {
    vi.mocked(assertWithinSharedRateLimit).mockClear();
    vi.mocked(verifyStripeSignature).mockReset();
  });

  it('fails closed when the RevenueCat secret is missing and does not rate-limit', async () => {
    const controller = new BillingController({} as any, { get: vi.fn() } as any);

    await expect(controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      undefined,
      { event: { id: 'evt-1', type: 'RENEWAL', app_user_id: 'venue-1' } } as any,
    )).rejects.toBeInstanceOf(UnauthorizedException);
    expect(assertWithinSharedRateLimit).not.toHaveBeenCalled();
  });

  it('rejects an invalid RevenueCat secret before rate limiting', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'REVENUECAT_WEBHOOK_SECRET' ? 'secret' : undefined)),
    };
    const controller = new BillingController({} as any, config as any);

    await expect(controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer wrong',
      { event: { id: 'evt-1', type: 'RENEWAL', app_user_id: 'venue-1' } } as any,
    )).rejects.toBeInstanceOf(UnauthorizedException);
    expect(assertWithinSharedRateLimit).not.toHaveBeenCalled();
  });

  it('rate-limits only after a valid RevenueCat secret', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'REVENUECAT_WEBHOOK_SECRET' ? 'secret' : undefined)),
    };
    const controller = new BillingController({} as any, config as any);

    await expect(controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      {
        event: {
          id: 'evt-1',
          type: 'RENEWAL',
          app_user_id: 'venue-1',
          product_id: 'another-app.product',
        },
      } as any,
    )).resolves.toEqual({ ok: true, ignored: true });
    expect(assertWithinSharedRateLimit).toHaveBeenCalledOnce();
  });

  it('ignores signed RevenueCat events for unrelated products', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'REVENUECAT_WEBHOOK_SECRET' ? 'secret' : undefined)),
    };
    const controller = new BillingController({} as any, config as any);

    await expect(controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      {
        event: {
          id: 'evt-1',
          type: 'RENEWAL',
          app_user_id: 'venue-1',
          product_id: 'another-app.product',
        },
      } as any,
    )).resolves.toEqual({ ok: true, ignored: true });
  });

  it('ignores signed RevenueCat events with neither product nor entitlement identifiers', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'REVENUECAT_WEBHOOK_SECRET' ? 'secret' : undefined)),
    };
    const controller = new BillingController({} as any, config as any);

    await expect(controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      { event: { id: 'evt-no-product', type: 'RENEWAL', app_user_id: 'venue-1' } } as any,
    )).resolves.toEqual({ ok: true, ignored: true });
  });

  it('fails closed when the Stripe secret is missing and does not rate-limit', async () => {
    const controller = new BillingController({} as any, { get: vi.fn() } as any);

    await expect(controller.stripeWebhook(
      { ip: '127.0.0.1', rawBody: Buffer.from('{}') } as any,
      'sig',
      { id: 'evt_1', type: 'customer.subscription.updated' } as any,
    )).rejects.toBeInstanceOf(UnauthorizedException);
    expect(assertWithinSharedRateLimit).not.toHaveBeenCalled();
    expect(verifyStripeSignature).not.toHaveBeenCalled();
  });

  it('rejects an invalid Stripe signature before rate limiting', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'STRIPE_WEBHOOK_SECRET' ? 'whsec_test' : undefined)),
    };
    vi.mocked(verifyStripeSignature).mockReturnValue(false);
    const controller = new BillingController({} as any, config as any);

    await expect(controller.stripeWebhook(
      { ip: '127.0.0.1', rawBody: Buffer.from('{}') } as any,
      'bad-sig',
      { id: 'evt_1', type: 'customer.subscription.updated' } as any,
    )).rejects.toBeInstanceOf(UnauthorizedException);
    expect(verifyStripeSignature).toHaveBeenCalledOnce();
    expect(assertWithinSharedRateLimit).not.toHaveBeenCalled();
  });

  it('rate-limits only after a valid Stripe signature', async () => {
    const config = {
      get: vi.fn((key: string) => (key === 'STRIPE_WEBHOOK_SECRET' ? 'whsec_test' : undefined)),
    };
    vi.mocked(verifyStripeSignature).mockReturnValue(true);
    const controller = new BillingController({} as any, config as any);

    await expect(controller.stripeWebhook(
      { ip: '127.0.0.1', rawBody: Buffer.from('{}') } as any,
      'good-sig',
      { id: 'evt_1', type: 'invoice.created', data: { object: {} } } as any,
    )).resolves.toEqual({ ok: true, ignored: true });
    expect(verifyStripeSignature).toHaveBeenCalledOnce();
    expect(assertWithinSharedRateLimit).toHaveBeenCalledOnce();
  });
});

describe('BillingController applySubscription P2002 handling', () => {
  function makeController(transactionImpl: () => Promise<unknown>) {
    const prisma = { $transaction: vi.fn(transactionImpl) };
    const controller = new BillingController(prisma as any, { get: vi.fn() } as any);
    return { controller, prisma };
  }

  const input = {
    venueId: 'venue-1',
    status: 'active' as const,
    planId: 'plan-1',
    eventId: 'evt-1',
    eventType: 'customer.subscription.updated',
  };

  it('swallows a P2002 on the SubscriptionEvent replay-dedupe constraint', async () => {
    const error = Object.assign(new Error('duplicate'), { code: 'P2002', meta: { target: ['source', 'externalEventId'] } });
    const { controller } = makeController(() => Promise.reject(error));

    await expect(controller.applyStripeSubscription(input)).resolves.toEqual({ ok: true, duplicate: true });
  });

  it('re-throws a P2002 on any other constraint instead of returning a fake success', async () => {
    // e.g. Subscription.externalSubscriptionId already bound to a different
    // venue — a real conflict, not a replayed webhook delivery. Swallowing
    // this would tell Stripe/RevenueCat the event was handled when the
    // venue's subscription state was never actually updated.
    const error = Object.assign(new Error('duplicate'), { code: 'P2002', meta: { target: ['externalSubscriptionId'] } });
    const { controller } = makeController(() => Promise.reject(error));

    await expect(controller.applyStripeSubscription(input)).rejects.toBe(error);
  });

  it('re-throws a P2002 with no meta.target at all', async () => {
    const error = Object.assign(new Error('duplicate'), { code: 'P2002' });
    const { controller } = makeController(() => Promise.reject(error));

    await expect(controller.applyStripeSubscription(input)).rejects.toBe(error);
  });

  it('ignores single-venue RevenueCat events when the owner has more than one venue', async () => {
    const prisma = {
      subscription: { findMany: vi.fn().mockResolvedValue([]) },
      venue: { findUnique: vi.fn().mockResolvedValue(null) },
      profile: {
        findMany: vi.fn().mockResolvedValue([
          { venueId: 'venue-latest', createdAt: new Date(2000) },
          { venueId: 'venue-older', createdAt: new Date(1000) },
        ]),
      },
      $transaction: vi.fn().mockImplementation(async (cb: any) => cb({
        $executeRaw: vi.fn().mockResolvedValue(undefined),
        venue: { findUnique: vi.fn().mockResolvedValue({ id: 'venue-latest' }), update: vi.fn().mockResolvedValue({}) },
        subscription: { findFirst: vi.fn().mockResolvedValue(null), create: vi.fn().mockResolvedValue({}) },
        subscriptionEvent: { create: vi.fn().mockResolvedValue({}) },
      })),
    };
    const config = {
      get: vi.fn((key: string) => {
        if (key === 'REVENUECAT_WEBHOOK_SECRET') return 'secret';
        if (key === 'REVENUECAT_ALLOWED_PRODUCT_IDS') return 'com.venuewrangler.monthly';
        return undefined;
      }),
    };
    const controller = new BillingController(prisma as any, config as any);

    const result = await controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      {
        event: {
          id: 'evt-1',
          type: 'INITIAL_PURCHASE',
          app_user_id: 'user-multi-owner',
          product_id: 'com.venuewrangler.monthly',
          purchased_at_ms: Date.now(),
          expiration_at_ms: Date.now() + 86400000,
        },
      } as any,
    );
    expect(result).toEqual({ ok: true, ignored: true });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('updates only the canonical payer for a multi-venue RevenueCat entitlement', async () => {
    const updatedVenueIds: string[] = [];
    const prisma = {
      subscription: { findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-a' }]) },
      venue: { findUnique: vi.fn().mockResolvedValue(null) },
      profile: { findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-a' }, { venueId: 'venue-b' }]) },
      $transaction: vi.fn().mockImplementation(async (cb: any) => cb({
        $executeRaw: vi.fn().mockResolvedValue(undefined),
        venue: {
          findUnique: vi.fn(({ where }: any) => Promise.resolve({ id: where.id })),
          update: vi.fn(({ where }: any) => {
            updatedVenueIds.push(where.id);
            return Promise.resolve({});
          }),
        },
        subscription: { findFirst: vi.fn().mockResolvedValue(null), create: vi.fn().mockResolvedValue({}) },
        subscriptionEvent: { create: vi.fn().mockResolvedValue({}) },
      })),
    };
    const config = {
      get: vi.fn((key: string) => {
        if (key === 'REVENUECAT_WEBHOOK_SECRET') return 'secret';
        if (key === 'REVENUECAT_ALLOWED_PRODUCT_IDS') return 'com.venuewrangler.multivenue.399';
        return undefined;
      }),
    };
    const controller = new BillingController(prisma as any, config as any);

    await controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      {
        event: {
          id: 'evt-multi',
          type: 'INITIAL_PURCHASE',
          app_user_id: 'user-multi-owner',
          product_id: 'com.venuewrangler.multivenue.399',
          entitlement_ids: ['multi_venue'],
        },
      } as any,
    );

    expect(updatedVenueIds).toEqual(['venue-a']);
    expect(prisma.$transaction).toHaveBeenCalledOnce();
  });

  it('ignores a RevenueCat app_user_id that happens to match another venue\'s id', async () => {
    // Regression for F01: subscriberId must never be looked up as Venue.id.
    // A forged app_user_id equal to a victim's venueId must fall through to
    // profile resolution (and fail closed, since no profile has that userId)
    // rather than resolving straight to the victim's venue.
    const venueFindUnique = vi.fn();
    const prisma = {
      subscription: { findMany: vi.fn().mockResolvedValue([]) },
      venue: { findUnique: venueFindUnique },
      profile: { findMany: vi.fn().mockResolvedValue([]) },
      $transaction: vi.fn(),
    };
    const config = {
      get: vi.fn((key: string) => {
        if (key === 'REVENUECAT_WEBHOOK_SECRET') return 'secret';
        if (key === 'REVENUECAT_ALLOWED_PRODUCT_IDS') return 'com.venuewrangler.monthly';
        return undefined;
      }),
    };
    const controller = new BillingController(prisma as any, config as any);

    const result = await controller.revenueCatWebhook(
      { ip: '127.0.0.1' } as any,
      'Bearer secret',
      {
        event: {
          id: 'evt-forged',
          type: 'INITIAL_PURCHASE',
          app_user_id: 'victim-venue-id',
          product_id: 'com.venuewrangler.monthly',
          purchased_at_ms: Date.now(),
          expiration_at_ms: Date.now() + 86400000,
        },
      } as any,
    );

    expect(venueFindUnique).not.toHaveBeenCalled();
    expect(result).toEqual({ ok: true, ignored: true });
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('does not resolve unknown Stripe references through coincidental profile user ids', async () => {
    const prisma = {
      subscription: { findFirst: vi.fn().mockResolvedValue(null) },
      profile: { findMany: vi.fn().mockResolvedValue([{ venueId: 'venue-wrong' }]) },
    };
    const controller = new BillingController(prisma as any, { get: vi.fn() } as any);

    await expect((controller as any).resolveStripeVenueIdByRefs(null, 'sub_collision', 'cus_collision'))
      .resolves.toBeNull();
    expect(prisma.profile.findMany).not.toHaveBeenCalled();
  });
});

describe('BillingController Stripe invoice subscription reference', () => {
  function makeController() {
    const subscriptionFindFirst = vi.fn().mockResolvedValue(null);
    const prisma = {
      venue: { findUnique: vi.fn().mockResolvedValue(null) },
      subscription: { findFirst: subscriptionFindFirst },
      $transaction: vi.fn().mockResolvedValue(undefined),
    };
    const config = { get: vi.fn() };
    const controller = new BillingController(prisma as any, config as any);
    return { controller, prisma, subscriptionFindFirst };
  }

  const invoiceBase = { id: 'in_123', customer: null, currency: 'usd', status: 'paid' };

  it('reads the subscription id from parent.subscription_details (Stripe 2025-03-31+)', async () => {
    const { controller, subscriptionFindFirst } = makeController();
    subscriptionFindFirst.mockResolvedValue({ venueId: 'venue-1' });

    await (controller as any).recordStripeInvoice(
      { ...invoiceBase, parent: { subscription_details: { subscription: 'sub_new' } } },
      { id: 'evt-1', type: 'invoice.payment_succeeded' },
      new Date(),
    );

    // The venue must be resolvable from the nested field alone; before this the
    // handler read only the removed top-level `invoice.subscription`.
    const where = subscriptionFindFirst.mock.calls[0][0].where;
    expect(JSON.stringify(where)).toContain('sub_new');
  });

  it('still reads the legacy top-level field for older API versions', async () => {
    const { controller, subscriptionFindFirst } = makeController();
    subscriptionFindFirst.mockResolvedValue({ venueId: 'venue-1' });

    await (controller as any).recordStripeInvoice(
      { ...invoiceBase, subscription: 'sub_legacy' },
      { id: 'evt-2', type: 'invoice.payment_succeeded' },
      new Date(),
    );

    const where = subscriptionFindFirst.mock.calls[0][0].where;
    expect(JSON.stringify(where)).toContain('sub_legacy');
  });

  it('prefers the nested field when both are present', async () => {
    const { controller, subscriptionFindFirst } = makeController();
    subscriptionFindFirst.mockResolvedValue({ venueId: 'venue-1' });

    await (controller as any).recordStripeInvoice(
      { ...invoiceBase, subscription: 'sub_legacy', parent: { subscription_details: { subscription: 'sub_new' } } },
      { id: 'evt-3', type: 'invoice.payment_succeeded' },
      new Date(),
    );

    const where = JSON.stringify(subscriptionFindFirst.mock.calls[0][0].where);
    expect(where).toContain('sub_new');
    expect(where).not.toContain('sub_legacy');
  });

  it('logs instead of silently dropping an invoice it cannot match to a venue', async () => {
    const { controller, prisma } = makeController();
    const warn = vi.spyOn((controller as any).logger, 'warn').mockImplementation(() => undefined);

    await (controller as any).recordStripeInvoice(
      { ...invoiceBase },
      { id: 'evt-4', type: 'invoice.payment_succeeded' },
      new Date(),
    );

    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('in_123'));
  });
});
