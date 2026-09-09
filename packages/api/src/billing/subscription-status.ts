import type { SubscriptionStatus } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { effectiveSubscriptionStatus, isMultiVenuePlan } from './billing-coverage';

export async function resolveVenueSubscriptionStatus(
  prisma: PrismaService,
  input: { venueId: string; venueStatus?: SubscriptionStatus | null; venuePlatform?: string | null; trialEndsAt?: Date | null },
): Promise<SubscriptionStatus | null> {
  // Resolve only the selected venue's explicit relation. Never infer coverage
  // from membership or let a cached Venue.active hide payer cancellation.
  const subscription = await prisma.subscription.findFirst({
    where: { venueId: input.venueId }, include: { billingSubscription: true },
  });
  if (subscription?.billingSubscriptionId) {
    const payer = subscription.billingSubscription;
    return payer && !payer.billingSubscriptionId && isMultiVenuePlan(payer)
      ? effectiveSubscriptionStatus(payer) : 'expired';
  }
  if (subscription) return effectiveSubscriptionStatus(subscription);
  // Only pre-subscription app-native trials may fall back to the profile.
  if (!input.venuePlatform && input.trialEndsAt && input.trialEndsAt.getTime() > Date.now()) return 'trialing';
  return 'expired';
}
