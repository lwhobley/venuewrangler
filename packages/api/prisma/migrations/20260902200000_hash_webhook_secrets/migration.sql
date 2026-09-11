-- Hash any legacy plaintext webhook secrets at rest using SHA-256.
-- PosConnection, ReservationConnection, and Venue already support sha256: prefixed secrets
-- via secretsMatch() in common/webhook-auth.ts.

-- pgcrypto may already be installed in public (fresh CI) or extensions
-- (Supabase). CREATE EXTENSION IF NOT EXISTS does not relocate it. Use the
-- built-in SHA-256 function instead, and hash UTF-8 text exactly like Node.
-- A text::bytea cast would interpret backslashes instead of preserving them.

UPDATE "PosConnection"
SET "webhookSecret" = 'sha256:' || encode(pg_catalog.sha256(convert_to("webhookSecret", 'UTF8')), 'hex')
WHERE "webhookSecret" IS NOT NULL
  AND "webhookSecret" NOT LIKE 'sha256:%';

UPDATE "ReservationConnection"
SET "webhookSecret" = 'sha256:' || encode(pg_catalog.sha256(convert_to("webhookSecret", 'UTF8')), 'hex')
WHERE "webhookSecret" IS NOT NULL
  AND "webhookSecret" NOT LIKE 'sha256:%';

UPDATE "Venue"
SET "leadsWebhookSecret" = 'sha256:' || encode(pg_catalog.sha256(convert_to("leadsWebhookSecret", 'UTF8')), 'hex')
WHERE "leadsWebhookSecret" IS NOT NULL
  AND "leadsWebhookSecret" NOT LIKE 'sha256:%';
