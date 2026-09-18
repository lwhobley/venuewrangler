import { BadRequestException } from '@nestjs/common';
import type { Prisma, Subscription } from '@prisma/client';

export function isMultiVenuePlan(subscription: { planId: string; platform?: string | null; priceCents?: number }): boolean {
  return subscription.planId === 'venueflow_multi_venue_5'
    || subscription.planId === 'com.venuewrangler.multivenue.399'
    // Existing Stripe rows store price IDs rather than our internal plan ID.
    || (subscription.platform === 'stripe' && subscription.priceCents === 39900);
}

export function effectiveSubscriptionStatus(subscription: Pick<Subscription, 'status' | 'trialEndsAt' | 'currentPeriodEnd' | 'platform'>) {
  if (subscription.status === 'trialing' && (!subscription.trialEndsAt || subscription.trialEndsAt.getTime() <= Date.now())) return 'expired';
  if (subscription.status === 'active' && subscription.platform === 'apple'
      && (!subscription.currentPeriodEnd || subscription.currentPeriodEnd.getTime() <= Date.now())) return 'expired';
  return subscription.status;
}

// Call inside an unscoped transaction, after verifying billing permissions at
// both venues. The payer lock is shared with webhook updates and registrations.
export async function assertCoverageCapacity(tx: Prisma.TransactionClient, payerId: string, targetId?: string) {
  const count = await tx.subscription.count({ where: { billingSubscriptionId: payerId, ...(targetId ? { id: { not: targetId } } : {}) } });
  if (count >= 4) throw new BadRequestException('This subscription already covers five venues.');
}

export const COVERED_SUBSCRIPTION_DATA = {
  status: 'expired', platform: null, trialStartedAt: null, trialEndsAt: null,
  currentPeriodStart: null, currentPeriodEnd: null, externalSubscriptionId: null,
  externalCustomerId: null, revenueCatSubscriberId: null, cancelAtPeriodEnd: false,
} as const;
