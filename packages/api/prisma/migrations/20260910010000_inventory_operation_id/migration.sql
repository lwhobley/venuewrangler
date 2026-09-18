ALTER TABLE "BarInventoryMovement" ADD COLUMN "operationId" TEXT;
CREATE UNIQUE INDEX "BarInventoryMovement_venueId_operationId_key"
ON "BarInventoryMovement"("venueId", "operationId");
