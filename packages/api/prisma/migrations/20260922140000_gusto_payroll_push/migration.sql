ALTER TABLE "Profile" ADD COLUMN "payrollEmployeeId" TEXT;
CREATE UNIQUE INDEX "Profile_venueId_payrollEmployeeId_key" ON "Profile"("venueId", "payrollEmployeeId");

ALTER TABLE "PayrollExport" ADD COLUMN "externalRef" TEXT;

CREATE TABLE "PayrollConnection" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "provider" TEXT NOT NULL,
  "companyUuid" TEXT NOT NULL,
  "accessTokenCipher" TEXT NOT NULL,
  "refreshTokenCipher" TEXT NOT NULL,
  "tokenExpiresAt" TIMESTAMP(3) NOT NULL,
  "status" "IntegrationStatus" NOT NULL DEFAULT 'connected',
  "connectedBy" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "PayrollConnection_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "PayrollConnection_venueId_provider_key" ON "PayrollConnection"("venueId", "provider");
CREATE INDEX "PayrollConnection_venueId_idx" ON "PayrollConnection"("venueId");
ALTER TABLE "PayrollConnection"
  ADD CONSTRAINT "PayrollConnection_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PayrollConnection" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "PayrollTimeSheetPush" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "timeEntryId" TEXT NOT NULL,
  "externalId" TEXT,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "PayrollTimeSheetPush_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "PayrollTimeSheetPush_venueId_timeEntryId_key" ON "PayrollTimeSheetPush"("venueId", "timeEntryId");
CREATE INDEX "PayrollTimeSheetPush_venueId_idx" ON "PayrollTimeSheetPush"("venueId");
ALTER TABLE "PayrollTimeSheetPush"
  ADD CONSTRAINT "PayrollTimeSheetPush_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "PayrollTimeSheetPush" ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON TABLE "PayrollConnection" FROM anon;
    REVOKE ALL ON TABLE "PayrollTimeSheetPush" FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON TABLE "PayrollConnection" FROM authenticated;
    REVOKE ALL ON TABLE "PayrollTimeSheetPush" FROM authenticated;
  END IF;
END
$$;
