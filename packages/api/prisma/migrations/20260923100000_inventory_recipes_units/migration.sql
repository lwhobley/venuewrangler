ALTER TABLE "BarInventoryItem"
  ADD COLUMN "baseUnit" TEXT NOT NULL DEFAULT 'each',
  ADD COLUMN "baseQuantity" DOUBLE PRECISION NOT NULL DEFAULT 1;

CREATE TABLE "InventoryRecipe" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "normalizedName" TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "InventoryRecipe_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "InventoryRecipe_venueId_normalizedName_key" ON "InventoryRecipe"("venueId", "normalizedName");
CREATE INDEX "InventoryRecipe_venueId_idx" ON "InventoryRecipe"("venueId");
ALTER TABLE "InventoryRecipe" ADD CONSTRAINT "InventoryRecipe_venueId_fkey"
  FOREIGN KEY ("venueId") REFERENCES "Venue"("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE TABLE "InventoryRecipeLine" (
  "id" TEXT NOT NULL,
  "recipeId" TEXT NOT NULL,
  "itemId" TEXT NOT NULL,
  "quantity" DOUBLE PRECISION NOT NULL,
  "unit" TEXT NOT NULL,
  CONSTRAINT "InventoryRecipeLine_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "InventoryRecipeLine_recipeId_itemId_key" ON "InventoryRecipeLine"("recipeId", "itemId");
CREATE INDEX "InventoryRecipeLine_itemId_idx" ON "InventoryRecipeLine"("itemId");
ALTER TABLE "InventoryRecipeLine" ADD CONSTRAINT "InventoryRecipeLine_recipeId_fkey"
  FOREIGN KEY ("recipeId") REFERENCES "InventoryRecipe"("id") ON DELETE CASCADE ON UPDATE CASCADE;
ALTER TABLE "InventoryRecipeLine" ADD CONSTRAINT "InventoryRecipeLine_itemId_fkey"
  FOREIGN KEY ("itemId") REFERENCES "BarInventoryItem"("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE TABLE "PosInventoryConsumption" (
  "id" TEXT NOT NULL,
  "venueId" TEXT NOT NULL,
  "provider" "PosProvider" NOT NULL,
  "externalCheckId" TEXT NOT NULL,
  "itemId" TEXT NOT NULL,
  "quantity" DOUBLE PRECISION NOT NULL,
  "appliedQuantity" DOUBLE PRECISION NOT NULL DEFAULT 0,
  "cycle" INTEGER NOT NULL DEFAULT 1,
  "reversedAt" TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "PosInventoryConsumption_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "PosInventoryConsumption_venueId_provider_externalCheckId_itemId_key"
  ON "PosInventoryConsumption"("venueId", "provider", "externalCheckId", "itemId");
CREATE INDEX "PosInventoryConsumption_venueId_createdAt_idx" ON "PosInventoryConsumption"("venueId", "createdAt");
ALTER TABLE "PosInventoryConsumption" ADD CONSTRAINT "PosInventoryConsumption_itemId_fkey"
  FOREIGN KEY ("itemId") REFERENCES "BarInventoryItem"("id") ON DELETE CASCADE ON UPDATE CASCADE;
