# features/documents

Batch 3: the venue document library (SOPs/manuals/recipes/menus/training/forms), ported from
`packages/api/src/modules/documents`. The last of the three modules the Phase 4 validation
report listed as unported (`crm`, `documents`, `observability`).

## What's real here

- `domain/venue_document.dart` — `VenueDocument`, with `categories`/`managerOnlyCategories`
  matching legacy's `DOCUMENT_CATEGORIES`/`MANAGER_ONLY_CATEGORIES` exactly (`form`/`other` are
  manager-only; the rest are staff-readable).
- `data/documents_repository.dart` — reads (`getDocuments`) go straight through RLS on
  `public.documents` (`supabase/migrations/20261003003000`); **uploads cannot go through RLS at
  all** and must call the `documents-upload` Edge Function, since RLS has no way to verify a
  ClamAV scan happened. Deletes go through a plain RLS-gated `DELETE`, same as every other
  manager-only-delete table in this codebase; the actual Storage object cleanup happens
  automatically via an `AFTER DELETE` trigger that enqueues a `storage_deletion_jobs` row (the
  same worker queue media-cleanup already uses), not from this repository.
- `application/document_picker_service.dart` — a thin interface over the new `file_picker`
  dependency, same reasoning as `features/media`'s `ImagePickerService`: UI/tests never depend
  on the plugin directly.
- `presentation/documents_screen.dart` — list + upload (file picker → title/category dialog) +
  delete + open-via-signed-URL. Does not duplicate server-side role checks (same convention as
  `features/crm`): the upload/delete controls are shown to everyone, and a non-manager gets a
  clear `PermissionDeniedError` message back from the server rather than the button being
  hidden client-side.

## Server-side pieces this depends on

- `supabase/migrations/20261003003000_documents_schema.sql` — the `documents` table, its
  category-aware RLS, and the `staff-documents` Storage bucket's tightened policies (no more
  direct client INSERT — that was a real gap in the Phase 3 scaffolding, since the bucket
  existed with a generic "any venue member can upload" policy that would have let a client skip
  the ClamAV scan entirely).
- `supabase/functions/documents-upload/index.ts` — auth → manager-role check → filename
  sanitize → base64 decode → size cap (10MB) → magic-byte MIME validation
  (`_shared/document-bytes.ts`) → ClamAV scan (`_shared/clamav.ts`) → Storage upload → DB insert
  (rolling back the Storage object if the DB insert fails). This is the only path that can
  create a `documents` row.

## Known gaps — read before treating this as production-ready

- **ClamAV scanning has not been live-tested.** This sandbox has no reachable `clamd` instance.
  The magic-byte MIME validation and the ClamAV response-parsing logic (`assertAllowedDocumentBytes`,
  `assertCleanClamAvResponse`) were both unit-tested against real file signatures and real clamd
  response formats (Node, type-stripped), but the actual `Deno.connect` TCP round-trip to a real
  clamd has not been exercised. `CLAMAV_HOST` is unset in `supabase/.env.example` by design —
  every upload will 503 until a real, network-reachable clamd is configured.
- **`file_picker` is a brand-new dependency, unverified.** No Flutter SDK is available in this
  environment to run `flutter pub get`/`flutter build`, so this dependency resolving and
  compiling cleanly has not been confirmed, unlike every pre-existing dependency in this repo.
- **No Content-Disposition control on download.** Legacy generated a presigned S3 URL with an
  explicit `inline`-vs-`attachment` header depending on mime type; this port's
  `getSignedUrl` just calls Supabase Storage's `createSignedUrl(path, 120)` with no override,
  since the exact signature for a content-disposition override in the installed
  `supabase_flutter` version could not be confirmed without the SDK. The browser/OS picks
  inline-vs-download on its own instead.
- **No uploader name shown.** Legacy's list included the uploader's display name (a Prisma
  join). The equivalent Supabase embed (`documents.uploaded_by` → `profiles.display_name`)
  wasn't used here because it goes through `auth.users`, not a direct FK to `profiles`, and
  whether PostgREST actually infers that relationship without an explicit join hint could not
  be confirmed without a live query test — left out rather than guessed.
- **Not offline-writable**, unlike tasks/checklists/incidents/media. Legacy had no offline mode
  either, and document upload inherently needs a live connection anyway (the scan is
  synchronous), so this was never in scope for the offline-queue work.
