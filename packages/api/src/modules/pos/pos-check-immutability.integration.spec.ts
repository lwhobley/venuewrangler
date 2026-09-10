import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { PrismaClient } from '@prisma/client';
import { setupTestDb } from '../../test/setup-test-db';
import { PosController } from './pos.controller';
import { hashWebhookSecret } from '../../common/webhook-auth';

// Unit tests mock $executeRaw, so they can prove the query text carries the
// paid/void guard but not that Postgres actually enforces it. This runs the
// real atomic INSERT ... ON CONFLICT against a real database to prove the
// core sale amounts on a closed check survive a replayed/corrected delivery
// while tip, total, and status remain correctable — with no separate
// check-then-write step for a concurrent delivery to land inside.
describe('POS check immutability (PostgreSQL)', () => {
  let prisma: PrismaClient;
  let teardown = async () => {};
  let venueId: string;
  const secret = randomUUID();

  beforeAll(async () => {
    ({ prisma, teardown } = await setupTestDb());
    const venue = await prisma.venue.create({
      data: { name: 'POS Immutability Test', code: randomUUID(), latitude: 0, longitude: 0, geofenceRadiusM: 100 },
    });
    venueId = venue.id;
    await prisma.posConnection.create({
      data: { venueId, provider: 'toast', status: 'connected', webhookSecret: hashWebhookSecret(secret) },
    });
  });

  afterAll(async () => {
    if (venueId) await prisma.venue.delete({ where: { id: venueId } });
    await teardown();
  });

  it('locks core sale amounts on a paid check but still allows a tip adjustment and a void correction', async () => {
    const controller = new PosController(prisma as never);
    const externalCheckId = randomUUID();
    const openedAt = Date.now();

    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{
        externalCheckId, openedAt, subtotalCents: 2000, taxCents: 150, tipCents: 300, totalCents: 2450, status: 'paid',
      }],
    } as never);

    const paid = await prisma.posCheck.findFirstOrThrow({ where: { venueId, externalCheckId } });
    expect(paid.status).toBe('paid');
    expect(paid.subtotalCents).toBe(2000);

    // A replayed/corrected delivery tries to rewrite the sale itself — must
    // not land, in the same atomic statement that also applies the tip.
    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{
        externalCheckId, openedAt, subtotalCents: 999, taxCents: 999, discountCents: 999,
        tipCents: 400, totalCents: 2550, status: 'paid',
      }],
    } as never);

    const afterReplay = await prisma.posCheck.findFirstOrThrow({ where: { venueId, externalCheckId } });
    expect(afterReplay.subtotalCents).toBe(2000); // locked
    expect(afterReplay.taxCents).toBe(150); // locked
    expect(afterReplay.discountCents).toBeNull(); // locked
    expect(afterReplay.tipCents).toBe(400); // tip adjustment applied
    expect(afterReplay.totalCents).toBe(2550); // total recomputed for the tip applied

    // A status correction (paid -> void, e.g. a disputed charge) is a real
    // workflow, not a rewrite attempt, and must still go through.
    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{
        externalCheckId, openedAt, subtotalCents: 2000, taxCents: 150, tipCents: 400, totalCents: 2550, status: 'void',
      }],
    } as never);

    const voided = await prisma.posCheck.findFirstOrThrow({ where: { venueId, externalCheckId } });
    expect(voided.status).toBe('void');
  });

  it('does not let a late "open" delivery reopen a paid check and unlock its amounts', async () => {
    // The CASE guards on subtotal/tax/discount/comp/promo key off the
    // row's *current* status being paid/void. If a stale or late 'open'
    // webhook were allowed to flip a closed check back to 'open', the very
    // next delivery would see status = 'open' and rewrite those "locked"
    // fields freely — a broken state machine, not a real correction like
    // paid<->void.
    const controller = new PosController(prisma as never);
    const externalCheckId = randomUUID();
    const openedAt = Date.now();

    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{ externalCheckId, openedAt, subtotalCents: 2000, taxCents: 150, tipCents: 300, totalCents: 2450, status: 'paid' }],
    } as never);

    // A late/out-of-order delivery claims the check is still open.
    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{ externalCheckId, openedAt, subtotalCents: 2000, taxCents: 150, tipCents: 300, totalCents: 2450, status: 'open' }],
    } as never);

    const stillPaid = await prisma.posCheck.findFirstOrThrow({ where: { venueId, externalCheckId } });
    expect(stillPaid.status).toBe('paid');

    // If the reopen had landed, this would succeed. It must not.
    await controller.ingest({ ip: '127.0.0.1' } as never, venueId, secret, {
      provider: 'toast',
      checks: [{ externalCheckId, openedAt, subtotalCents: 1, taxCents: 1, tipCents: 300, totalCents: 302, status: 'open' }],
    } as never);

    const stillLocked = await prisma.posCheck.findFirstOrThrow({ where: { venueId, externalCheckId } });
    expect(stillLocked.status).toBe('paid');
    expect(stillLocked.subtotalCents).toBe(2000);
    expect(stillLocked.taxCents).toBe(150);
  });
});
