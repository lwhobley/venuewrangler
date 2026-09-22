import { PrismaService } from '../../prisma/prisma.service';

export function unpaidDepositBlocksSeating(reservation: {
  depositDueCents?: number | null;
  depositStatus?: string | null;
}): boolean {
  return (reservation.depositDueCents ?? 0) > 0
    && reservation.depositStatus !== 'paid'
    && reservation.depositStatus !== 'waived';
}

export async function markReservationDepositPaid(
  prisma: PrismaService,
  input: {
    venueId: string;
    reservationId: string;
    amountCents: number;
    checkoutSessionId: string;
    paymentIntentId: string | null;
  },
): Promise<'paid' | 'ignored'> {
  const reservation = await prisma.reservation.findFirst({
    where: { id: input.reservationId, venueId: input.venueId, deletedAt: null },
    select: { id: true, depositDueCents: true, depositStatus: true },
  });
  if (!reservation || reservation.depositStatus === 'paid' || reservation.depositStatus === 'waived') return 'ignored';
  if (!reservation.depositDueCents || reservation.depositDueCents !== input.amountCents) return 'ignored';
  const updated = await prisma.reservation.updateMany({
    where: {
      id: reservation.id,
      venueId: input.venueId,
      depositDueCents: input.amountCents,
      depositStatus: { notIn: ['paid', 'waived'] },
    },
    data: {
      depositStatus: 'paid',
      depositPaidAt: new Date(),
      depositCheckoutSessionId: input.checkoutSessionId,
      depositPaymentIntentId: input.paymentIntentId,
    },
  });
  return updated.count > 0 ? 'paid' : 'ignored';
}

export function unpaidBeoDepositBlocksContract(beo: {
  depositCents?: number | null;
  depositStatus?: string | null;
}): boolean {
  return (beo.depositCents ?? 0) > 0 && beo.depositStatus !== 'paid' && beo.depositStatus !== 'waived';
}

export async function markBeoDepositPaid(
  prisma: PrismaService,
  input: {
    venueId: string;
    beoId: string;
    amountCents: number;
    checkoutSessionId: string;
    paymentIntentId: string | null;
  },
): Promise<'paid' | 'ignored'> {
  const beo = await prisma.crmBeo.findFirst({
    where: { id: input.beoId, venueId: input.venueId },
    select: { id: true, depositCents: true, depositStatus: true },
  });
  if (!beo || beo.depositStatus === 'paid' || beo.depositStatus === 'waived') return 'ignored';
  if (!beo.depositCents || beo.depositCents !== input.amountCents) return 'ignored';
  const updated = await prisma.crmBeo.updateMany({
    where: {
      id: beo.id,
      venueId: input.venueId,
      depositCents: input.amountCents,
      OR: [{ depositStatus: null }, { depositStatus: { notIn: ['paid', 'waived'] } }],
    },
    data: {
      depositStatus: 'paid',
      depositPaidAt: new Date(),
      depositCheckoutSessionId: input.checkoutSessionId,
      depositPaymentIntentId: input.paymentIntentId,
    },
  });
  return updated.count > 0 ? 'paid' : 'ignored';
}
