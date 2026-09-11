-- Reservation.externalId is nullable, and Postgres treats every NULL as
-- distinct — the previous plain unique on (venueId, source, externalId)
-- never actually deduped direct/manual reservations (externalId IS NULL),
-- and provided no protection there. Replace it with a partial unique index
-- that only applies where externalId is present, which is the only case
-- where dedup is meaningful (webhook-sourced bookings).
DO $$
DECLARE
  dup_count integer;
BEGIN
  SELECT count(*) INTO dup_count FROM (
    SELECT "venueId", "source", "externalId" FROM "Reservation"
    WHERE "externalId" IS NOT NULL
    GROUP BY "venueId", "source", "externalId" HAVING count(*) > 1
  ) d;
  IF dup_count > 0 THEN
    RAISE EXCEPTION 'Aborting migration: % duplicate (venueId, source, externalId) pairs exist on Reservation', dup_count;
  END IF;
END $$;

DROP INDEX IF EXISTS "Reservation_venueId_source_externalId_key";
CREATE UNIQUE INDEX "Reservation_venueId_source_externalId_key"
  ON "Reservation"("venueId", "source", "externalId")
  WHERE "externalId" IS NOT NULL;
CREATE INDEX "Reservation_venueId_source_externalId_idx" ON "Reservation"("venueId", "source", "externalId");
