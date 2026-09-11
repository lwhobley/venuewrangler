-- Preserve cancelled event work for history without leaving it actionable.
ALTER TABLE "EventExecutionWorkspace"
  ADD COLUMN "isArchived" BOOLEAN NOT NULL DEFAULT false;

-- Repair workspaces whose sources were cancelled before the archive flag existed.
UPDATE "EventExecutionWorkspace" w
SET "isArchived" = true
WHERE (
  w."sourceType" = 'reservation' AND EXISTS (
    SELECT 1 FROM "Reservation" r
    WHERE r.id = w."sourceId" AND r."venueId" = w."venueId"
      AND (r.status = 'cancelled' OR r."deletedAt" IS NOT NULL)
  )
) OR (
  w."sourceType" = 'beo' AND EXISTS (
    SELECT 1 FROM "CrmBeo" b
    WHERE b.id = w."sourceId" AND b."venueId" = w."venueId" AND b.status = 'cancelled'
  )
) OR (
  w."sourceType" = 'venue-event' AND EXISTS (
    SELECT 1 FROM "VenueEvent" e JOIN "Reservation" r ON r.id = e."reservationId"
    WHERE e.id = w."sourceId" AND e."venueId" = w."venueId" AND r."venueId" = w."venueId"
      AND (r.status = 'cancelled' OR r."deletedAt" IS NOT NULL)
  )
);
