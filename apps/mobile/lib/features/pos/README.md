# Bidirectional POS Integration Feature

Port of legacy NestJS `pos` module with an explicit architecture expansion: **bidirectional synchronization**, starting with **Toast POS**.

## Asymmetry & Implemented Scope

The legacy NestJS pos module was strictly **ingest-only** and never called external vendor APIs. Under the new bidirectional architecture:

### 1. Inbound Ingest-Only (Legacy Parity)
- Providers: `toast`, `square`, `clover`, `shopify_pos`, `lightspeed_restaurant`, `spoton`, `generic`.
- Supported Inbound Capabilities:
  - Check ingestion with table, server, guest count, and line items.
  - Idempotent upsert via unique constraint `(venue_id, provider, external_check_id)` preventing duplicate revenue reporting on webhook retries.
  - Labor punches, tips, and service charges remain ingest-driven from webhook payloads.

### 2. Outbound Operations (New Architectural Capability)
- Primary Vendor: **Toast POS** (selected as first target vendor).
- Supported Outbound Operations:
  - `update_item_availability_86`: Push real-time 86'd (out-of-stock) item statuses directly to Toast restaurant terminals.
  - `sync_menu_item`: Scaffolding for pushing menu modifications and item updates.
  - `void_item`: Scaffolding for item cancellation commands.
- Reliability & Queue Architecture:
  - Commands are enqueued into `public.pos_outbound_commands` with exponential retry counts (`attempts`, `max_attempts`) and worker claiming (`claim_pos_outbound_commands_batch` using `FOR UPDATE SKIP LOCKED`).
  - Edge Function `supabase/functions/toast-pos/index.ts` mediates authenticated outbound calls with manager authorization checks, looking up venue credentials securely.
- Security:
  - `webhook_secret_hash` and `credentials_encrypted` are strictly revoked from `authenticated` at the database column level.
