import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { Prisma, PrismaClient } from '@prisma/client';
import { setupTestDb } from '../test/setup-test-db';
import { hashWebhookSecret } from '../common/webhook-auth';

// These two migrations contain only simple statements, with no function bodies.
function migrationStatements(name: string) {
  return readFileSync(resolve(__dirname, '../../prisma/migrations', name, 'migration.sql'), 'utf8')
    .replace(/--[^\n]*/g, '')
    .split(';')
    .map((statement) => statement.trim())
    .filter(Boolean);
}

describe('production review migration regressions', () => {
  let prisma: PrismaClient;
  let teardown: () => Promise<void> = async () => {};

  beforeAll(async () => {
    const db = await setupTestDb();
    prisma = db.prisma;
    teardown = db.teardown;
  });
  afterAll(async () => { await teardown(); });

  it('hashes legacy webhook secrets exactly like the API, preserving existing hashes and nulls', async () => {
    // Temporary tables shadow the application tables only within this connection.
    // Run the actual migration expressions without changing any other test data.
    await prisma.$transaction(async (tx) => {
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "PosConnection" (id int, "webhookSecret" text) ON COMMIT DROP');
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "ReservationConnection" (id int, "webhookSecret" text) ON COMMIT DROP');
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "Venue" (id int, "leadsWebhookSecret" text) ON COMMIT DROP');
      const fixtures = ['plain-fixture', 'caf\u00e9-\u2603', String.raw`literal\backslash`, hashWebhookSecret('already-hashed'), null];
      const expected = fixtures.map((value) => value === null || value.startsWith('sha256:') ? value : hashWebhookSecret(value));
      for (const [index, value] of fixtures.entries()) {
        await tx.$executeRaw`INSERT INTO "PosConnection" VALUES (${index}, ${value})`;
        await tx.$executeRaw`INSERT INTO "ReservationConnection" VALUES (${index}, ${value})`;
        await tx.$executeRaw`INSERT INTO "Venue" VALUES (${index}, ${value})`;
      }
      const updates = migrationStatements('20260902200000_hash_webhook_secrets').filter((sql) => sql.startsWith('UPDATE'));
      expect(updates).toHaveLength(3);
      // A second run must not double-hash the stored values.
      for (let run = 0; run < 2; run++) {
        for (const sql of updates) await tx.$executeRawUnsafe(sql);
        for (const [table, column] of [['PosConnection', 'webhookSecret'], ['ReservationConnection', 'webhookSecret'], ['Venue', 'leadsWebhookSecret']]) {
          const rows = await tx.$queryRawUnsafe<Array<{ value: string | null }>>(`SELECT "${column}" AS value FROM "${table}" ORDER BY id`);
          expect(rows.map((row) => row.value)).toEqual(expected);
        }
      }
    });
  });

  it('archives only cancelled or deleted sources, including linked operational events', async () => {
    await prisma.$transaction(async (tx: Prisma.TransactionClient) => {
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "EventExecutionWorkspace" (id text, "venueId" text, "sourceType" text, "sourceId" text) ON COMMIT DROP');
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "Reservation" (id text, "venueId" text, status text, "deletedAt" timestamptz) ON COMMIT DROP');
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "CrmBeo" (id text, "venueId" text, status text) ON COMMIT DROP');
      await tx.$executeRawUnsafe('CREATE TEMP TABLE "VenueEvent" (id text, "venueId" text, "reservationId" text) ON COMMIT DROP');
      await tx.$executeRawUnsafe(`INSERT INTO "Reservation" VALUES
        ('cancelled', 'venue-a', 'cancelled', NULL),
        ('deleted', 'venue-a', 'confirmed', NOW()),
        ('active', 'venue-a', 'confirmed', NULL)`);
      await tx.$executeRawUnsafe(`INSERT INTO "CrmBeo" VALUES ('beo-cancelled', 'venue-a', 'cancelled'), ('beo-active', 'venue-a', 'confirmed')`);
      await tx.$executeRawUnsafe(`INSERT INTO "VenueEvent" VALUES ('event-cancelled', 'venue-a', 'cancelled'), ('event-active', 'venue-a', 'active')`);
      await tx.$executeRawUnsafe(`INSERT INTO "EventExecutionWorkspace" VALUES
        ('1', 'venue-a', 'reservation', 'cancelled'),
        ('2', 'venue-a', 'reservation', 'deleted'),
        ('3', 'venue-a', 'reservation', 'active'),
        ('4', 'venue-a', 'beo', 'beo-cancelled'),
        ('5', 'venue-a', 'beo', 'beo-active'),
        ('6', 'venue-a', 'venue-event', 'event-cancelled'),
        ('7', 'venue-a', 'venue-event', 'event-active'),
        ('8', 'venue-b', 'reservation', 'cancelled')`);
      for (const sql of migrationStatements('20260902213000_event_execution_workspace_archive')) {
        await tx.$executeRawUnsafe(sql);
      }
      const archived = await tx.$queryRaw<Array<{ id: string }>>`SELECT id FROM "EventExecutionWorkspace" WHERE "isArchived" = true ORDER BY id`;
      expect(archived.map((row) => row.id)).toEqual(['1', '2', '4', '6']);
    });
  });
});
