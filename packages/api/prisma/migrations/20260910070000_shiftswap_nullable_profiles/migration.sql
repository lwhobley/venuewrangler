-- ShiftSwap.requesterProfileId/targetProfileId were required and Cascade
-- from Profile. Deleting an account removes every Profile that user holds
-- (see app.controller.ts's account-delete flow), which cascade-deleted the
-- ENTIRE swap row for both parties — including the still-active other
-- party's pending/accepted swap, with no trace it ever existed.
--
-- Make both nullable with SetNull instead, so the row survives as a record
-- ("this swap involved someone who no longer has an account") rather than
-- vanishing. Every read site is updated in the same change to treat a null
-- profile id as "that party is gone" instead of assuming it's populated.

ALTER TABLE "ShiftSwap" ALTER COLUMN "requesterProfileId" DROP NOT NULL;
ALTER TABLE "ShiftSwap" ALTER COLUMN "targetProfileId" DROP NOT NULL;

ALTER TABLE "ShiftSwap" DROP CONSTRAINT IF EXISTS "ShiftSwap_requesterProfileId_fkey";
ALTER TABLE "ShiftSwap" ADD CONSTRAINT "ShiftSwap_requesterProfileId_fkey"
  FOREIGN KEY ("requesterProfileId") REFERENCES "Profile"("id") ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "ShiftSwap" DROP CONSTRAINT IF EXISTS "ShiftSwap_targetProfileId_fkey";
ALTER TABLE "ShiftSwap" ADD CONSTRAINT "ShiftSwap_targetProfileId_fkey"
  FOREIGN KEY ("targetProfileId") REFERENCES "Profile"("id") ON DELETE SET NULL ON UPDATE CASCADE;
