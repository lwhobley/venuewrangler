ALTER TABLE "Reservation" ADD COLUMN "depositCheckoutSessionId" TEXT;
ALTER TABLE "Reservation" ADD COLUMN "depositPaymentIntentId" TEXT;
ALTER TABLE "Reservation" ADD COLUMN "depositPaidAt" TIMESTAMP(3);
