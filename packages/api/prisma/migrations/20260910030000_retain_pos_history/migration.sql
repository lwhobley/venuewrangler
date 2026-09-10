-- PosCheck and PosLaborPunch are onDelete: Cascade from Venue with no
-- archive table, so an account deletion that cascades a Venue (the only
-- place a Venue is ever deleted in application code) destroyed revenue and
-- labor history with no retention. These tables give the account-delete flow
-- somewhere to archive that data into first, the same way RetainedTimeEntry
-- already does for TimeEntry.

CREATE TABLE "RetainedPosCheck" (
    "id" TEXT NOT NULL,
    "originVenueId" TEXT NOT NULL,
    "originVenueName" TEXT,
    "provider" TEXT NOT NULL,
    "externalCheckId" TEXT NOT NULL,
    "tableLabel" TEXT,
    "serverName" TEXT,
    "guestName" TEXT,
    "openedAt" TIMESTAMP(3) NOT NULL,
    "closedAt" TIMESTAMP(3),
    "subtotalCents" INTEGER NOT NULL,
    "taxCents" INTEGER,
    "tipCents" INTEGER NOT NULL,
    "totalCents" INTEGER NOT NULL,
    "status" TEXT NOT NULL,
    "originUpdatedAt" TIMESTAMP(3) NOT NULL,
    "retainedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RetainedPosCheck_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "RetainedPosCheck_originVenueId_idx" ON "RetainedPosCheck"("originVenueId");
CREATE INDEX "RetainedPosCheck_retainedAt_idx" ON "RetainedPosCheck"("retainedAt");

CREATE TABLE "RetainedPosLaborPunch" (
    "id" TEXT NOT NULL,
    "originVenueId" TEXT NOT NULL,
    "originVenueName" TEXT,
    "provider" TEXT NOT NULL,
    "externalEmployeeId" TEXT NOT NULL,
    "employeeName" TEXT NOT NULL,
    "clockInAt" TIMESTAMP(3) NOT NULL,
    "clockOutAt" TIMESTAMP(3),
    "regularMinutes" INTEGER,
    "overtimeMinutes" INTEGER,
    "regularPayCents" INTEGER,
    "overtimePayCents" INTEGER,
    "totalPayCents" INTEGER,
    "businessDate" TEXT NOT NULL,
    "retainedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RetainedPosLaborPunch_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "RetainedPosLaborPunch_originVenueId_idx" ON "RetainedPosLaborPunch"("originVenueId");
CREATE INDEX "RetainedPosLaborPunch_retainedAt_idx" ON "RetainedPosLaborPunch"("retainedAt");
