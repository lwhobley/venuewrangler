-- E03 (production review): a schedule could still read "Draft" to the manager
-- while staff were already working from those shifts. Publish state lived on
-- the venue as a single timestamp covering every week at once, so publishing
-- one week marked them all published and staff saw every week regardless.

CREATE TABLE "SchedulePublication" (
  "id"            TEXT NOT NULL,
  "venueId"       TEXT NOT NULL,
  "weekStart"     TEXT NOT NULL,
  "publishedAt"   TIMESTAMP(3) NOT NULL,
  "publishedById" TEXT,
  "createdAt"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt"     TIMESTAMP(3) NOT NULL,
  CONSTRAINT "SchedulePublication_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "SchedulePublication_venueId_weekStart_key"
  ON "SchedulePublication" ("venueId", "weekStart");
CREATE INDEX "SchedulePublication_venueId_idx" ON "SchedulePublication" ("venueId");

ALTER TABLE "SchedulePublication"
  ADD CONSTRAINT "SchedulePublication_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- RLS, in the same migration that creates the table: the Supabase Data API
-- lockdown enabled it per-table on everything that existed then, and ENABLE is
-- not covered by ALTER DEFAULT PRIVILEGES, so a new table lands unprotected
-- without this. Publish state is server-owned and must never be reachable from
-- a browser role.
ALTER TABLE "SchedulePublication" ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON TABLE "SchedulePublication" FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON TABLE "SchedulePublication" FROM authenticated;
  END IF;
END
$$;

-- Backfill so nothing staff can see today disappears: every week that already
-- has shifts, in a venue that had published at all, is treated as published at
-- that venue's existing timestamp. Venues that never published stay unpublished
-- and their staff were not being shown a published schedule anyway.
INSERT INTO "SchedulePublication" ("id", "venueId", "weekStart", "publishedAt", "publishedById", "createdAt", "updatedAt")
SELECT
  gen_random_uuid()::TEXT,
  v."id",
  s."weekStart",
  v."schedulePublishedAt",
  v."schedulePublishedById",
  NOW(),
  NOW()
FROM "Venue" v
JOIN (SELECT DISTINCT "venueId", "weekStart" FROM "ScheduleShift") s ON s."venueId" = v."id"
WHERE v."schedulePublishedAt" IS NOT NULL
ON CONFLICT ("venueId", "weekStart") DO NOTHING;
