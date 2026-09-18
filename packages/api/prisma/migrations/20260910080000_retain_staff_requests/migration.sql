-- StaffRequest.profile is onDelete: Cascade, and an approved time-off/PTO/
-- sick request is the audit trail for why sickHoursAccrued/ptoHoursAccrued
-- changed on the departing account's Profile — the same wage/hour
-- compliance category that justified RetainedTimeEntry. This table gives
-- account deletion somewhere to archive approved requests into before the
-- cascade destroys them.

CREATE TABLE "RetainedStaffRequest" (
    "id" TEXT NOT NULL,
    "originVenueId" TEXT NOT NULL,
    "originVenueName" TEXT,
    "profileFullName" TEXT,
    "kind" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "details" TEXT NOT NULL,
    "requestedForDate" TEXT,
    "requestedRangeStart" TEXT,
    "requestedRangeEnd" TEXT,
    "responseNotes" TEXT,
    "originCreatedAt" TIMESTAMP(3) NOT NULL,
    "originReviewedAt" TIMESTAMP(3),
    "retainedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "RetainedStaffRequest_pkey" PRIMARY KEY ("id")
);

CREATE INDEX "RetainedStaffRequest_originVenueId_idx" ON "RetainedStaffRequest"("originVenueId");
CREATE INDEX "RetainedStaffRequest_retainedAt_idx" ON "RetainedStaffRequest"("retainedAt");
