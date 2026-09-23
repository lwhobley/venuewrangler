ALTER TABLE "BarInventoryMovement"
  ADD COLUMN "reviewRequired" BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN "reviewedAt" TIMESTAMP(3),
  ADD COLUMN "reviewedBy" TEXT;
