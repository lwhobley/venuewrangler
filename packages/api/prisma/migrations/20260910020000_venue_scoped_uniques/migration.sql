-- CrmContract.contractNumber and PushToken.token were globally unique even
-- though both are legitimately per-venue: a randomly generated contract
-- number from one venue could collide with another venue's, and a physical
-- device token is meant to be able to hold a separate row per venue a staff
-- member works at. This tightens both to venue-scoped uniqueness instead.
--
-- Fail loudly rather than silently corrupt data: if any cross-venue
-- duplicates already exist (they cannot, today, because the old constraints
-- were stricter than what we are moving to — but this migration should not
-- assume that forever), abort instead of building an index over dirty data.
DO $$
DECLARE
  dup_contract_count integer;
  dup_token_count integer;
BEGIN
  SELECT count(*) INTO dup_contract_count FROM (
    SELECT "venueId", "contractNumber" FROM "CrmContract"
    GROUP BY "venueId", "contractNumber" HAVING count(*) > 1
  ) d;
  IF dup_contract_count > 0 THEN
    RAISE EXCEPTION 'Aborting migration: % duplicate (venueId, contractNumber) pairs exist on CrmContract', dup_contract_count;
  END IF;

  SELECT count(*) INTO dup_token_count FROM (
    SELECT "venueId", "token" FROM "PushToken"
    GROUP BY "venueId", "token" HAVING count(*) > 1
  ) d;
  IF dup_token_count > 0 THEN
    RAISE EXCEPTION 'Aborting migration: % duplicate (venueId, token) pairs exist on PushToken', dup_token_count;
  END IF;
END $$;

-- CrmContract: contractNumber -> (venueId, contractNumber)
DROP INDEX IF EXISTS "CrmContract_contractNumber_key";
CREATE UNIQUE INDEX "CrmContract_venueId_contractNumber_key" ON "CrmContract"("venueId", "contractNumber");

-- PushToken: token -> (venueId, token), keep a plain index on token alone
-- for the cross-venue "disable dead device" update in notifications.service.ts.
DROP INDEX IF EXISTS "PushToken_token_key";
CREATE UNIQUE INDEX "PushToken_venueId_token_key" ON "PushToken"("venueId", "token");
CREATE INDEX "PushToken_token_idx" ON "PushToken"("token");
