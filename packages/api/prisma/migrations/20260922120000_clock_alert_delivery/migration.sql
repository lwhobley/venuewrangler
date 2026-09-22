-- Dedupe row for pushed late/missed clock alerts. NotificationEvent has no
-- unique key, so without this the 10-minute cron would page managers on every tick.

CREATE TABLE "ClockAlertDelivery" (
  "id"        TEXT NOT NULL,
  "venueId"   TEXT NOT NULL,
  "profileId" TEXT NOT NULL,
  "kind"      TEXT NOT NULL,
  "localDate" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "ClockAlertDelivery_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "ClockAlertDelivery_venueId_profileId_kind_localDate_key"
  ON "ClockAlertDelivery" ("venueId", "profileId", "kind", "localDate");
CREATE INDEX "ClockAlertDelivery_venueId_localDate_idx"
  ON "ClockAlertDelivery" ("venueId", "localDate");
CREATE INDEX "ClockAlertDelivery_profileId_idx"
  ON "ClockAlertDelivery" ("profileId");

ALTER TABLE "ClockAlertDelivery"
  ADD CONSTRAINT "ClockAlertDelivery_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "ClockAlertDelivery"
  ADD CONSTRAINT "ClockAlertDelivery_profileId_fkey"
  FOREIGN KEY ("profileId") REFERENCES "Profile"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "ClockAlertDelivery" ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON TABLE "ClockAlertDelivery" FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON TABLE "ClockAlertDelivery" FROM authenticated;
  END IF;
END
$$;

CREATE TRIGGER "ClockAlertDelivery_profile_tenant_fk"
BEFORE INSERT OR UPDATE OF "venueId", "profileId" ON "ClockAlertDelivery"
FOR EACH ROW EXECUTE FUNCTION public."assertTenantReferenceMatchesVenue"('profileId', 'Profile');
