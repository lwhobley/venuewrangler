import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BadRequestException, ServiceUnavailableException } from '@nestjs/common';
import { AppBillingController } from './app-billing.controller';

vi.mock('../../common/rate-limit', () => ({
  assertWithinSharedRateLimit: vi.fn().mockResolvedValue(undefined),
}));
vi.mock('../../billing/stripe-api', () => ({
  stripeRequest: vi.fn(),
}));

import { assertWithinSharedRateLimit } from '../../common/rate-limit';
import { stripeRequest } from '../../billing/stripe-api';

function makeController(configValues: Record<string, string | undefined> = {}) {
  const prisma: any = {
    subscription: {
      findFirst: vi.fn().mockResolvedValue(null),
      findUnique: vi.fn().mockResolvedValue(null),
      findMany: vi.fn().mockResolvedValue([]),
      count: vi.fn().mockResolvedValue(0),
      update: vi.fn().mockResolvedValue({}),
      create: vi.fn().mockResolvedValue({}),
    },
    venue: { update: vi.fn().mockResolvedValue({}) },
    $executeRaw: vi.fn().mockResolvedValue(undefined),
  };
  prisma.$transaction = vi.fn(async (cb: any) => cb(prisma));

  const defaults: Record<string, string | undefined> = {
    STRIPE_SECRET_KEY: 'sk_test_123',
    STRIPE_PRICE_ID: 'price_configured',
    APP_WEB_URL: 'https://venuewrangler.com',
    ...configValues,
  };
  const config = { get: vi.fn((key: string) => defaults[key]) };
  const profiles = {
    getProfile: vi.fn(),
    requireBillingProfile: vi.fn(),
  };

  const controller = new AppBillingController(prisma, config as any, profiles as any);
  return { controller, prisma, config, profiles };
}

const billingViewer = { id: 'owner-1', role: 'owner', allAccess: false, venueId: 'venue-1', fullName: 'Owner Olivia' };
const user = { sub: 'user-1' } as any;

beforeEach(() => {
  // Module-level vi.fn() mocks (created inside vi.mock factories) are not
  // reset by vi.restoreAllMocks() — that only applies to vi.spyOn mocks — so
  // clear call history and implementations explicitly between tests.
  vi.mocked(stripeRequest).mockReset();
  vi.mocked(assertWithinSharedRateLimit).mockReset().mockResolvedValue(undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('AppBillingController', () => {
  describe('getMyVenueBilling', () => {
    it('returns null when the caller has no venue profile', async () => {
      const { controller, profiles } = makeController();
      profiles.getProfile.mockResolvedValue(null);

      await expect(controller.getMyVenueBilling(user)).resolves.toBeNull();
    });

    it('returns null when the venue has no subscription row', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      prisma.subscription.findFirst.mockResolvedValue(null);

      await expect(controller.getMyVenueBilling(user)).resolves.toBeNull();
    });

    it('maps subscription fields, converting dates to epoch ms', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      prisma.subscription.findFirst.mockResolvedValue({
        venueId: 'venue-1', status: 'active', platform: 'stripe',
        trialStartedAt: null, trialEndsAt: null,
        currentPeriodStart: new Date('2026-07-01T00:00:00Z'),
        currentPeriodEnd: new Date('2026-08-01T00:00:00Z'),
        cancelAtPeriodEnd: false, cancelledAt: null,
        planId: 'plan-1', priceCents: 9999, currency: 'usd',
      });

      const result = await controller.getMyVenueBilling(user);

      expect(result).toMatchObject({
        venueId: 'venue-1', status: 'active', platform: 'stripe',
        currentPeriodStart: new Date('2026-07-01T00:00:00Z').getTime(),
        currentPeriodEnd: new Date('2026-08-01T00:00:00Z').getTime(),
      });
    });
  });

  describe('createStripeCheckout', () => {
    it('rejects when Stripe is not configured', async () => {
      const { controller, profiles } = makeController({ STRIPE_SECRET_KEY: undefined });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);

      await expect(controller.createStripeCheckout(user)).rejects.toThrow(ServiceUnavailableException);
    });

    it('rejects when the venue already has an active or trialing Stripe subscription', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ status: 'active', platform: 'stripe', externalCustomerId: 'cus_1' });

      await expect(controller.createStripeCheckout(user)).rejects.toThrow(BadRequestException);
    });

    it('rejects a second provider checkout when Apple already owns the allocation', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ status: 'active', platform: 'apple', externalCustomerId: 'venue-1' });
      vi.mocked(stripeRequest).mockResolvedValue({ url: 'https://checkout.stripe.com/session' });

      await expect(controller.createStripeCheckout(user)).rejects.toThrow('already has a billing allocation');
      expect(stripeRequest).not.toHaveBeenCalled();
    });

    it('uses the configured STRIPE_PRICE_ID without any Stripe price lookup', async () => {
      const { controller, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.mocked(stripeRequest).mockResolvedValue({ url: 'https://checkout.stripe.com/session' });

      await controller.createStripeCheckout(user);

      expect(stripeRequest).toHaveBeenCalledTimes(1);
      expect(vi.mocked(stripeRequest).mock.calls[0][2]).toBe('/checkout/sessions');
      const body = vi.mocked(stripeRequest).mock.calls[0][3] as any;
      expect(body.line_items).toEqual([{ price: 'price_configured', quantity: 1 }]);
      expect(body.metadata).toMatchObject({ venueId: 'venue-1' });
      expect(body.client_reference_id).toBe('venue-1');
    });

    it('includes the existing Stripe customer id when the venue already has one', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ status: 'cancelled', platform: 'stripe', externalCustomerId: 'cus_existing' });
      vi.mocked(stripeRequest).mockResolvedValue({ url: 'https://checkout.stripe.com/session' });

      await controller.createStripeCheckout(user);

      const body = vi.mocked(stripeRequest).mock.calls[0][3] as any;
      expect(body.customer).toBe('cus_existing');
    });

    it('throws ServiceUnavailableException when Stripe does not return a checkout url', async () => {
      const { controller, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.mocked(stripeRequest).mockResolvedValue({});

      await expect(controller.createStripeCheckout(user)).rejects.toThrow(ServiceUnavailableException);
    });

    it('applies a per-user rate limit', async () => {
      const { controller, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.mocked(stripeRequest).mockResolvedValue({ url: 'https://checkout.stripe.com/session' });

      await controller.createStripeCheckout(user);

      expect(assertWithinSharedRateLimit).toHaveBeenCalledWith(expect.anything(), 'stripe-checkout:user-1', 10, 60_000);
    });

    describe('price resolution fallback (STRIPE_PRICE_ID unset)', () => {
      it('reuses an existing Stripe price found by lookup_key', async () => {
        const { controller, profiles } = makeController({ STRIPE_PRICE_ID: undefined });
        profiles.requireBillingProfile.mockResolvedValue(billingViewer);
        vi.mocked(stripeRequest).mockImplementation(async (_secret, method, path) => {
          if (method === 'GET' && path === '/prices') return { data: [{ id: 'price_found' }] };
          if (path === '/checkout/sessions') return { url: 'https://checkout.stripe.com/session' };
          throw new Error(`unexpected stripe call: ${method} ${path}`);
        });

        await controller.createStripeCheckout(user);

        const checkoutCall = vi.mocked(stripeRequest).mock.calls.find((c) => c[2] === '/checkout/sessions');
        expect((checkoutCall?.[3] as any).line_items[0].price).toBe('price_found');
      });

      it('creates a product and price when none exists yet', async () => {
        const { controller, profiles } = makeController({ STRIPE_PRICE_ID: undefined });
        profiles.requireBillingProfile.mockResolvedValue(billingViewer);
        vi.mocked(stripeRequest).mockImplementation(async (_secret, method, path) => {
          if (method === 'GET' && path === '/prices') return { data: [] };
          if (path === '/products') return { id: 'prod_1' };
          if (path === '/prices') return { id: 'price_new' };
          if (path === '/checkout/sessions') return { url: 'https://checkout.stripe.com/session' };
          throw new Error(`unexpected stripe call: ${method} ${path}`);
        });

        await controller.createStripeCheckout(user);

        const checkoutCall = vi.mocked(stripeRequest).mock.calls.find((c) => c[2] === '/checkout/sessions');
        expect((checkoutCall?.[3] as any).line_items[0].price).toBe('price_new');
      });

      it('re-fetches the price by lookup_key when creation races with a concurrent request', async () => {
        const { controller, profiles } = makeController({ STRIPE_PRICE_ID: undefined });
        profiles.requireBillingProfile.mockResolvedValue(billingViewer);
        let priceGetCalls = 0;
        vi.mocked(stripeRequest).mockImplementation(async (_secret, method, path) => {
          if (method === 'GET' && path === '/prices') {
            priceGetCalls += 1;
            return priceGetCalls === 1 ? { data: [] } : { data: [{ id: 'price_claimed_by_other_request' }] };
          }
          if (path === '/products') return { id: 'prod_1' };
          if (path === '/prices') throw new Error('Stripe /prices failed with status 409');
          if (path === '/checkout/sessions') return { url: 'https://checkout.stripe.com/session' };
          throw new Error(`unexpected stripe call: ${method} ${path}`);
        });

        await controller.createStripeCheckout(user);

        const checkoutCall = vi.mocked(stripeRequest).mock.calls.find((c) => c[2] === '/checkout/sessions');
        expect((checkoutCall?.[3] as any).line_items[0].price).toBe('price_claimed_by_other_request');
      });

      it('caches the resolved price id across requests on the same controller instance', async () => {
        const { controller, profiles } = makeController({ STRIPE_PRICE_ID: undefined });
        profiles.requireBillingProfile.mockResolvedValue(billingViewer);
        vi.mocked(stripeRequest).mockImplementation(async (_secret, method, path) => {
          if (method === 'GET' && path === '/prices') return { data: [{ id: 'price_found' }] };
          if (path === '/checkout/sessions') return { url: 'https://checkout.stripe.com/session' };
          throw new Error(`unexpected stripe call: ${method} ${path}`);
        });

        await controller.createStripeCheckout(user);
        vi.mocked(stripeRequest).mockClear();
        await controller.createStripeCheckout(user);

        // Only the checkout-session call should remain; no repeated GET /prices lookup.
        expect(vi.mocked(stripeRequest).mock.calls).toHaveLength(1);
        expect(vi.mocked(stripeRequest).mock.calls[0][2]).toBe('/checkout/sessions');
      });
    });

    describe('in production, with STRIPE_PRICE_ID unset', () => {
      const originalNodeEnv = process.env.NODE_ENV;
      afterEach(() => {
        process.env.NODE_ENV = originalNodeEnv;
      });

      it('refuses to auto-create a Stripe price instead of minting one at the hardcoded fallback amount', async () => {
        process.env.NODE_ENV = 'production';
        const { controller, profiles } = makeController({ STRIPE_PRICE_ID: undefined });
        profiles.requireBillingProfile.mockResolvedValue(billingViewer);

        await expect(controller.createStripeCheckout(user)).rejects.toThrow(ServiceUnavailableException);
        expect(stripeRequest).not.toHaveBeenCalled();
      });
    });
  });

  describe('createStripePortal', () => {
    it('rejects when the venue has no Stripe subscription yet', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue(null);

      await expect(controller.createStripePortal(user)).rejects.toThrow(BadRequestException);
    });

    it('rejects when the subscription is on a non-Stripe platform', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ platform: 'apple', externalCustomerId: 'venue-1' });

      await expect(controller.createStripePortal(user)).rejects.toThrow('No Stripe subscription for this venue yet.');
    });

    it('creates a portal session for an existing Stripe customer', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ platform: 'stripe', externalCustomerId: 'cus_1' });
      vi.mocked(stripeRequest).mockResolvedValue({ url: 'https://billing.stripe.com/portal' });

      const result = await controller.createStripePortal(user);

      expect(result.url).toBe('https://billing.stripe.com/portal');
      const call = vi.mocked(stripeRequest).mock.calls[0];
      expect(call[2]).toBe('/billing_portal/sessions');
      expect((call[3] as any).customer).toBe('cus_1');
      expect((call[3] as any).return_url).toBe('https://venuewrangler.com/billing');
    });

    it('throws ServiceUnavailableException when Stripe does not return a portal url', async () => {
      const { controller, prisma, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      prisma.subscription.findFirst.mockResolvedValue({ platform: 'stripe', externalCustomerId: 'cus_1' });
      vi.mocked(stripeRequest).mockResolvedValue({});

      await expect(controller.createStripePortal(user)).rejects.toThrow(ServiceUnavailableException);
    });
  });

  describe('syncAppleSubscription', () => {
    const allowedBody = { productId: 'com.venuewrangler.monthly', entitlementId: 'pro' };

    afterEach(() => {
      vi.unstubAllGlobals();
    });

    it('rejects a productId that is not on the allow-list', async () => {
      const { controller, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);

      await expect(controller.syncAppleSubscription(user, { productId: 'com.other.app' } as any)).rejects.toThrow(BadRequestException);
    });

    it('rejects an entitlementId that is not on the allow-list', async () => {
      const { controller, profiles } = makeController();
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);

      await expect(controller.syncAppleSubscription(user, { productId: 'com.venuewrangler.monthly', entitlementId: 'not-pro' } as any)).rejects.toThrow(BadRequestException);
    });

    it('respects a custom REVENUECAT_ALLOWED_PRODUCT_IDS allow-list', async () => {
      const { controller, profiles } = makeController({ REVENUECAT_ALLOWED_PRODUCT_IDS: 'com.venuewrangler.monthly,com.venuewrangler.annual', REVENUECAT_API_KEY: undefined });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue(null);

      await expect(controller.syncAppleSubscription(user, { productId: 'com.venuewrangler.annual' } as any)).rejects.toThrow(
        'Apple subscription verification is not configured',
      );
    });

    it('fails explicitly when REVENUECAT_API_KEY is not configured', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: undefined });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue(null);
      const fetchSpy = vi.fn();
      vi.stubGlobal('fetch', fetchSpy);

      await expect(controller.syncAppleSubscription(user, allowedBody as any)).rejects.toThrow(ServiceUnavailableException);
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(prisma.$transaction).not.toHaveBeenCalled();
    });

    it('throws when the RevenueCat lookup itself fails', async () => {
      const { controller, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: false, statusText: 'Not Found', json: async () => ({ message: 'subscriber not found' }),
      }));

      await expect(controller.syncAppleSubscription(user, allowedBody as any)).rejects.toThrow('Could not verify RevenueCat subscription.');
    });

    it('rejects when no matching entitlement/subscription is active', async () => {
      const { controller, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true, json: async () => ({ subscriber: { entitlements: {}, subscriptions: {} } }),
      }));

      await expect(controller.syncAppleSubscription(user, allowedBody as any)).rejects.toThrow('No active RevenueCat entitlement found for this Apple subscription.');
    });

    it('rejects an expired entitlement', async () => {
      const { controller, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          subscriber: {
            entitlements: { pro: { product_identifier: 'com.venuewrangler.monthly', expires_date: '2020-01-01T00:00:00Z' } },
            subscriptions: {},
          },
        }),
      }));

      await expect(controller.syncAppleSubscription(user, allowedBody as any)).rejects.toThrow(BadRequestException);
    });

    it('retries RevenueCat verification when encountering a transient 500 server error', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      const fetchMock = vi.fn()
        .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({ message: 'server error' }) })
        .mockResolvedValueOnce({
          ok: true,
          status: 200,
          json: async () => ({
            subscriber: {
              entitlements: { pro: { product_identifier: 'com.venuewrangler.monthly', expires_date: '2030-01-01T00:00:00Z' } },
              subscriptions: {},
            },
          }),
        });
      vi.stubGlobal('fetch', fetchMock);

      await controller.syncAppleSubscription(user, allowedBody as any);
      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(prisma.venue.update).toHaveBeenCalledWith({
        where: { id: 'venue-1' },
        data: { subscriptionStatus: 'active', subscriptionPlatform: 'apple' },
      });
    });

    it('rejects an active entitlement that belongs to a different product', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          subscriber: {
            entitlements: {
              pro: {
                product_identifier: 'com.venuewrangler.monthly',
                expires_date: '2027-01-01T00:00:00Z',
              },
            },
            subscriptions: {},
          },
        }),
      }));

      await expect(controller.syncAppleSubscription(user, {
        productId: 'com.venuewrangler.multivenue.399',
        entitlementId: 'pro',
      } as any)).rejects.toThrow('RevenueCat entitlement does not match the requested Apple subscription product.');
      expect(prisma.$transaction).not.toHaveBeenCalled();
    });

    it('derives the multi-venue plan only from the RevenueCat-verified product', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      prisma.subscription.findFirst.mockResolvedValue(null);
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          subscriber: {
            entitlements: {
              multi_venue: {
                product_identifier: 'com.venuewrangler.multivenue.399',
                expires_date: '2027-01-01T00:00:00Z',
              },
            },
            subscriptions: {},
          },
        }),
      }));

      await controller.syncAppleSubscription(user, {
        productId: 'com.venuewrangler.multivenue.399',
        entitlementId: 'multi_venue',
      } as any);

      expect(prisma.subscription.create).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({ planId: 'venueflow_multi_venue_5', priceCents: 39900 }),
      }));
    });

    it('creates a new subscription row for an active entitlement, scoped to the caller venue', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      prisma.subscription.findFirst
        .mockResolvedValueOnce(null) // inside the transaction: existing lookup
        .mockResolvedValueOnce(null); // getMyVenueBilling at the end (no row yet is fine too, but let's return the created row)
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          subscriber: {
            entitlements: { pro: { product_identifier: 'com.venuewrangler.monthly', expires_date: '2027-01-01T00:00:00Z', purchase_date: '2026-01-01T00:00:00Z' } },
            subscriptions: {},
          },
        }),
      }));

      await controller.syncAppleSubscription(user, allowedBody as any);

      expect(prisma.venue.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: 'venue-1' },
        data: expect.objectContaining({ subscriptionStatus: 'active', subscriptionPlatform: 'apple' }),
      }));
      expect(prisma.subscription.create).toHaveBeenCalledWith(expect.objectContaining({
        data: expect.objectContaining({
          venueId: 'venue-1', status: 'active', platform: 'apple', planId: 'com.venuewrangler.monthly',
          externalCustomerId: 'user-1', revenueCatSubscriberId: 'user-1', trialStartedAt: null, trialEndsAt: null,
        }),
      }));
      expect(prisma.subscription.update).not.toHaveBeenCalled();
    });

    it('updates an existing subscription row for an active entitlement instead of creating a duplicate', async () => {
      const { controller, prisma, profiles } = makeController({ REVENUECAT_API_KEY: 'rc_key' });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue({ venueId: 'venue-1' });
      prisma.subscription.findFirst.mockResolvedValue({ id: 'sub-1', currentPeriodStart: null, currentPeriodEnd: null });
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({
          subscriber: {
            entitlements: { pro: { product_identifier: 'com.venuewrangler.monthly', expires_date: '2027-01-01T00:00:00Z', purchase_date: '2026-01-01T00:00:00Z' } },
            subscriptions: {},
          },
        }),
      }));

      await controller.syncAppleSubscription(user, allowedBody as any);

      expect(prisma.subscription.update).toHaveBeenCalledWith(expect.objectContaining({
        where: { id: 'sub-1' },
        data: expect.objectContaining({ status: 'active', platform: 'apple', cancelAtPeriodEnd: false, cancelledAt: null }),
      }));
      expect(prisma.subscription.create).not.toHaveBeenCalled();
    });

    it('applies a per-user rate limit', async () => {
      const { controller, profiles } = makeController({ REVENUECAT_API_KEY: undefined });
      profiles.requireBillingProfile.mockResolvedValue(billingViewer);
      profiles.getProfile.mockResolvedValue(null);

      await expect(controller.syncAppleSubscription(user, allowedBody as any)).rejects.toThrow(ServiceUnavailableException);

      expect(assertWithinSharedRateLimit).toHaveBeenCalledWith(expect.anything(), 'apple-sync:user-1', 10, 60_000);
    });
  });
});
