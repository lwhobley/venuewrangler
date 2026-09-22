import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PrismaClient } from '@prisma/client';
import { assertAllowedHost, assertNotProduction } from './database-target.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const API_DIR = resolve(HERE, '..');
const REPO_ROOT = resolve(API_DIR, '..', '..');

const URL_ENV_FILES = [
  join(API_DIR, '.env.local'),
  join(API_DIR, '.env'),
  join(REPO_ROOT, '.env.local'),
  join(REPO_ROOT, '.env'),
];

function fromEnvFiles(key, files) {
  for (const file of files) {
    try {
      const line = readFileSync(file, 'utf8')
        .split(/\r?\n/)
        .find((candidate) => candidate.startsWith(`${key}=`));
      if (!line) continue;
      const value = line.slice(key.length + 1).trim().replace(/^"|"$/g, '');
      if (value) return value;
    } catch {
      // Ignore missing files
    }
  }
  return undefined;
}

const databaseUrl = process.env.DATABASE_URL ?? fromEnvFiles('DATABASE_URL', URL_ENV_FILES);
if (!databaseUrl) {
  console.error('DATABASE_URL is required to verify subscriptions.');
  process.exit(1);
}

const guardEnv = {
  PRODUCTION_DB_FINGERPRINT:
    process.env.PRODUCTION_DB_FINGERPRINT ?? fromEnvFiles('PRODUCTION_DB_FINGERPRINT', URL_ENV_FILES),
  ALLOW_PRODUCTION_DB:
    process.env.ALLOW_PRODUCTION_DB ?? fromEnvFiles('ALLOW_PRODUCTION_DB', URL_ENV_FILES),
};

try {
  assertAllowedHost('DATABASE_URL', databaseUrl);
  assertNotProduction('DATABASE_URL', databaseUrl, guardEnv);
} catch (error) {
  console.error(`Database target check failed: ${error.message}`);
  process.exit(1);
}

const prisma = new PrismaClient({
  datasources: {
    db: { url: databaseUrl },
  },
});

async function main() {
  try {
    console.log('--- Inspecting Enish Houston & Subscriptions ---');
    const venues = await prisma.venue.findMany({
      where: {
        OR: [
          { name: { contains: 'Enish', mode: 'insensitive' } },
          { name: { contains: 'Houston', mode: 'insensitive' } },
        ],
      },
      include: {
        subscription: true,
        coveredSubscriptions: true,
      },
    });

    if (venues.length === 0) {
      console.log('No venue matching "Enish" or "Houston" found. Listing top venues:');
      const sample = await prisma.venue.findMany({
        take: 5,
        select: { id: true, name: true, subscriptionStatus: true, subscriptionPlatform: true },
      });
      for (const v of sample) {
        console.log(`- [${v.id}] "${v.name}" status=${v.subscriptionStatus} platform=${v.subscriptionPlatform}`);
      }
      return;
    }

    for (const venue of venues) {
      console.log(`\nVenue: "${venue.name}" (ID: ${venue.id})`);
      console.log(`  Status on Venue: ${venue.subscriptionStatus}, Platform: ${venue.subscriptionPlatform}`);
      const sub = venue.subscription;
      if (!sub) {
        console.log('  [ALERT] No Subscription row exists for this venue!');
        continue;
      }

      console.log(`  Subscription ID: ${sub.id}`);
      console.log(`    Status: ${sub.status}`);
      console.log(`    Platform: ${sub.platform}`);
      console.log(`    Plan ID: ${sub.planId}`);
      console.log(`    Price: ${sub.priceCents} ${sub.currency}`);
      console.log(`    External Subscription ID: ${sub.externalSubscriptionId ?? 'none'}`);
      console.log(`    External Customer ID: ${sub.externalCustomerId ?? 'none'}`);
      console.log(`    RevenueCat Subscriber ID: ${sub.revenueCatSubscriberId ?? 'none'}`);
      console.log(`    Billing Subscription ID: ${sub.billingSubscriptionId ?? 'none'}`);
      console.log(`    Current Period: ${sub.currentPeriodStart?.toISOString() ?? 'none'} -> ${sub.currentPeriodEnd?.toISOString() ?? 'none'}`);

      if (sub.platform === 'apple' && !sub.revenueCatSubscriberId && sub.externalCustomerId) {
        console.log(`  [ACTION NEEDED] Venue has Apple platform and externalCustomerId, but revenueCatSubscriberId is NULL.`);
        if (process.env.APPLY_BACKFILL === 'true') {
          await prisma.subscription.update({
            where: { id: sub.id },
            data: { revenueCatSubscriberId: sub.externalCustomerId },
          });
          console.log(`  [SUCCESS] Backfilled revenueCatSubscriberId to "${sub.externalCustomerId}".`);
        } else {
          console.log('  [NOTICE] Set APPLY_BACKFILL=true to apply backfill.');
        }
      } else {
        console.log('  [VERIFIED] Subscription state is consistent and canonical.');
      }
    }
  } finally {
    await prisma.$disconnect();
  }
}

main().catch((err) => {
  console.error('Subscription verification encountered an error:', err.message);
  process.exit(1);
});
