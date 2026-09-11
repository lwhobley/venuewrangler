ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "preferredContactMethod" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "smsOptIn" BOOLEAN;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "phoneticName" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "pronouns" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "honorific" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "guestTier" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "executiveRole" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "allergyNotes" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "allergyAirborne" BOOLEAN;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "allergyRequiresChefSignoff" BOOLEAN;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "allergyRequiresManagerTouch" BOOLEAN;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "dietaryRegimen" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "waterPreference" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "beverageSignature" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "diningPace" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "serviceInteraction" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "physicalComfort" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "seatingPreferences" TEXT;
ALTER TABLE "Guest" ADD COLUMN IF NOT EXISTS "environmentAvoidance" TEXT;

CREATE INDEX IF NOT EXISTS "Guest_venueId_guestTier_idx" ON "Guest"("venueId", "guestTier");

CREATE TABLE IF NOT EXISTS "GuestHouseholdLink" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "fromGuestId" TEXT NOT NULL,
  "toGuestId" TEXT NOT NULL,
  "relationship" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "GuestHouseholdLink_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX IF NOT EXISTS "GuestHouseholdLink_fromGuestId_toGuestId_key" ON "GuestHouseholdLink"("fromGuestId", "toGuestId");
CREATE INDEX IF NOT EXISTS "GuestHouseholdLink_venueId_idx" ON "GuestHouseholdLink"("venueId");
CREATE INDEX IF NOT EXISTS "GuestHouseholdLink_toGuestId_idx" ON "GuestHouseholdLink"("toGuestId");

ALTER TABLE "GuestHouseholdLink" DROP CONSTRAINT IF EXISTS "GuestHouseholdLink_venueId_fkey";
ALTER TABLE "GuestHouseholdLink" ADD CONSTRAINT "GuestHouseholdLink_venueId_fkey" FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "GuestHouseholdLink" DROP CONSTRAINT IF EXISTS "GuestHouseholdLink_fromGuestId_fkey";
ALTER TABLE "GuestHouseholdLink" ADD CONSTRAINT "GuestHouseholdLink_fromGuestId_fkey" FOREIGN KEY ("fromGuestId") REFERENCES "Guest"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "GuestHouseholdLink" DROP CONSTRAINT IF EXISTS "GuestHouseholdLink_toGuestId_fkey";
ALTER TABLE "GuestHouseholdLink" ADD CONSTRAINT "GuestHouseholdLink_toGuestId_fkey" FOREIGN KEY ("toGuestId") REFERENCES "Guest"("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE TABLE IF NOT EXISTS "GuestCrmNote" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "guestId" TEXT NOT NULL,
  "kind" TEXT NOT NULL,
  "text" TEXT NOT NULL,
  "occurredOn" TEXT,
  "authorName" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "GuestCrmNote_pkey" PRIMARY KEY ("id")
);

CREATE INDEX IF NOT EXISTS "GuestCrmNote_venueId_guestId_createdAt_idx" ON "GuestCrmNote"("venueId", "guestId", "createdAt");

ALTER TABLE "GuestCrmNote" DROP CONSTRAINT IF EXISTS "GuestCrmNote_venueId_fkey";
ALTER TABLE "GuestCrmNote" ADD CONSTRAINT "GuestCrmNote_venueId_fkey" FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "GuestCrmNote" DROP CONSTRAINT IF EXISTS "GuestCrmNote_guestId_fkey";
ALTER TABLE "GuestCrmNote" ADD CONSTRAINT "GuestCrmNote_guestId_fkey" FOREIGN KEY ("guestId") REFERENCES "Guest"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "GuestCrmNote" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "GuestHouseholdLink" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON "GuestCrmNote" FROM PUBLIC, anon, authenticated;
REVOKE ALL ON "GuestHouseholdLink" FROM PUBLIC, anon, authenticated;
