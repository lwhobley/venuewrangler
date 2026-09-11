-- E08 (production review): inventory screens recommended different actions
-- because two facts were missing from the schema.

-- 1. A movement recorded no cost, so waste and comp were valued at the item's
--    *current* unit cost. Changing today's cost silently rewrote the value of
--    every historical waste record. Capture the cost as of the movement.
ALTER TABLE "BarInventoryMovement"
  ADD COLUMN "unitCostCents" INTEGER;

-- Backfill with the item's current cost. That is the same figure the reports
-- were already using for these rows, so no number moves today; from here on
-- the value is frozen at write time instead of drifting with the item.
UPDATE "BarInventoryMovement" AS m
  SET "unitCostCents" = i."unitCostCents"
  FROM "BarInventoryItem" AS i
  WHERE m."itemId" = i."id" AND m."unitCostCents" IS NULL;

-- 2. Two items in one venue could share a SKU, and the barcode lookup takes
--    the first row it finds — so scanning a shared barcode opened whichever
--    item Postgres happened to return. Clear the SKU on the newer duplicates
--    (keeping the oldest item's), then enforce uniqueness. Clearing is the
--    conservative repair: the column is optional, nothing references it, and a
--    duplicate barcode is already broken for scanning. The affected items keep
--    every other field and can be rescanned.
WITH ranked AS (
  SELECT "id",
         ROW_NUMBER() OVER (PARTITION BY "venueId", "sku" ORDER BY "createdAt", "id") AS rn
  FROM "BarInventoryItem"
  WHERE "sku" IS NOT NULL AND "sku" <> ''
)
UPDATE "BarInventoryItem" AS i
  SET "sku" = NULL
  FROM ranked
  WHERE i."id" = ranked."id" AND ranked.rn > 1;

-- Empty-string SKUs are not a barcode; normalize them so they do not collide.
UPDATE "BarInventoryItem" SET "sku" = NULL WHERE "sku" = '';

-- Postgres treats NULLs as distinct in a unique index, so items with no SKU
-- are unaffected; this is the index Prisma's @@unique([venueId, sku]) expects.
CREATE UNIQUE INDEX "BarInventoryItem_venueId_sku_key"
  ON "BarInventoryItem" ("venueId", "sku");
