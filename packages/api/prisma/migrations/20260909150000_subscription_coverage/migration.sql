-- Additive migration. Existing allocations are not guessed from membership.
ALTER TABLE "Subscription" ADD COLUMN "revenueCatSubscriberId" TEXT;
ALTER TABLE "Subscription" ADD COLUMN "billingSubscriptionId" TEXT;
CREATE UNIQUE INDEX "Subscription_revenueCatSubscriberId_key" ON "Subscription"("revenueCatSubscriberId");
CREATE INDEX "Subscription_billingSubscriptionId_idx" ON "Subscription"("billingSubscriptionId");
ALTER TABLE "Subscription" ADD CONSTRAINT "Subscription_billingSubscriptionId_fkey"
  FOREIGN KEY ("billingSubscriptionId") REFERENCES "Subscription"("id") ON DELETE SET NULL ON UPDATE CASCADE;
ALTER TABLE "Subscription" ADD CONSTRAINT "Subscription_coverage_no_provider"
  CHECK ("billingSubscriptionId" IS NULL OR
    ("billingSubscriptionId" <> id AND "externalSubscriptionId" IS NULL
     AND "externalCustomerId" IS NULL AND "revenueCatSubscriberId" IS NULL
     AND platform IS NULL AND status = 'expired' AND "trialEndsAt" IS NULL));

-- Five venues total = one payer plus at most four covered venues. No chains.
CREATE FUNCTION public.check_subscription_coverage() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
DECLARE parent_id TEXT;
BEGIN
  IF NEW."billingSubscriptionId" IS NULL THEN RETURN NEW; END IF;
  SELECT "billingSubscriptionId" INTO parent_id FROM "Subscription"
    WHERE id = NEW."billingSubscriptionId" FOR UPDATE;
  IF parent_id IS NOT NULL OR EXISTS (
    SELECT 1 FROM "Subscription" WHERE "billingSubscriptionId" = NEW.id
  ) THEN RAISE EXCEPTION 'Billing coverage cannot form chains' USING ERRCODE = '23514'; END IF;
  IF (SELECT count(*) FROM "Subscription"
      WHERE "billingSubscriptionId" = NEW."billingSubscriptionId" AND id <> NEW.id) >= 4
  THEN RAISE EXCEPTION 'Billing subscription covers at most five venues' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.check_subscription_coverage() FROM PUBLIC;
CREATE TRIGGER subscription_coverage_check
  BEFORE INSERT OR UPDATE OF "billingSubscriptionId" ON "Subscription"
  FOR EACH ROW EXECUTE FUNCTION public.check_subscription_coverage();
