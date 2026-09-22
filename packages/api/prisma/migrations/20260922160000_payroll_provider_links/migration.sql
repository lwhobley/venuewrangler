ALTER TABLE "PayrollTimeSheetPush" ADD COLUMN "provider" TEXT NOT NULL DEFAULT 'gusto';
DROP INDEX "PayrollTimeSheetPush_venueId_timeEntryId_key";
CREATE UNIQUE INDEX "PayrollTimeSheetPush_venueId_provider_timeEntryId_key"
  ON "PayrollTimeSheetPush"("venueId", "provider", "timeEntryId");

CREATE TABLE "PayrollEmployeeMap" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "profileId" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "externalId" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "PayrollEmployeeMap_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "PayrollEmployeeMap_venueId_profileId_provider_key"
  ON "PayrollEmployeeMap"("venueId", "profileId", "provider");
CREATE UNIQUE INDEX "PayrollEmployeeMap_venueId_provider_externalId_key"
  ON "PayrollEmployeeMap"("venueId", "provider", "externalId");
CREATE INDEX "PayrollEmployeeMap_venueId_idx" ON "PayrollEmployeeMap"("venueId");
CREATE INDEX "PayrollEmployeeMap_profileId_idx" ON "PayrollEmployeeMap"("profileId");

ALTER TABLE "PayrollEmployeeMap"
  ADD CONSTRAINT "PayrollEmployeeMap_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PayrollEmployeeMap"
  ADD CONSTRAINT "PayrollEmployeeMap_profileId_fkey"
  FOREIGN KEY ("profileId") REFERENCES "Profile"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "PayrollEmployeeMap" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER "PayrollEmployeeMap_profile_tenant_fk"
BEFORE INSERT OR UPDATE OF "venueId", "profileId" ON "PayrollEmployeeMap"
FOR EACH ROW EXECUTE FUNCTION public."assertTenantReferenceMatchesVenue"('profileId', 'Profile');

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON TABLE "PayrollEmployeeMap" FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON TABLE "PayrollEmployeeMap" FROM authenticated;
  END IF;
END
$$;
