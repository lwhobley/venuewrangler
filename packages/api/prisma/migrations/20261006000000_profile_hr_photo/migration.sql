ALTER TABLE "Profile"
  ADD COLUMN "preferredName" TEXT,
  ADD COLUMN "hireDate" TIMESTAMP(3),
  ADD COLUMN "employmentType" TEXT,
  ADD COLUMN "emergencyContactName" TEXT,
  ADD COLUMN "emergencyContactRelationship" TEXT,
  ADD COLUMN "emergencyContactPhone" TEXT,
  ADD COLUMN "photoKey" TEXT,
  ADD COLUMN "photoMimeType" TEXT;
