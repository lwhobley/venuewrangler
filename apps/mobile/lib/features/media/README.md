# features/media

Phase 3: a small shared layer for evidence/document uploads to Supabase Storage, with
offline-writable retry — the "media-upload-retry metadata" item in the migration plan's
offline scope, and the last of the four workflows that list named (tasks, checklist
responses, incident drafts, media-upload retry).

`application/image_picker_service.dart` — a thin interface over `image_picker` so UI code and
widget tests never depend on the plugin directly; override `imagePickerServiceProvider` with
a fake in tests instead of mocking a platform channel.

`data/media_repository.dart` — `MediaRepository.uploadIncidentEvidence` does two idempotent
steps: upload the file to the `incident-evidence` Storage bucket (`upsert: true`, safe to
retry) and record its path in `public.incident_attachments`
(`supabase/migrations/20261002050000_incident_attachments.sql`) via a plain insert with
duplicate-key-is-success handling, same pattern as `features/checklists`. If the local file
referenced by a queued retry no longer exists on-device, that's a terminal failure
(`LocalFileMissingException`), surfaced as a conflict rather than retried forever.

`application/media_providers.dart` — providers plus `mediaMutationHandlersProvider`
(registered into `core/offline`'s handler registry by `app/bootstrap.dart`).

Currently wired into exactly one place: `features/incidents`' report dialog, which lets the
user attach a photo and handles it with the same try-online-then-queue pattern as the rest of
the offline-writable features — see the ordering note in `media_providers.dart` for why
queuing an evidence-upload mutation after an incident-report mutation (both FIFO in the same
queue) is enough to guarantee the incident exists before its attachment is inserted, without
extra coordination.

Not yet implemented: evidence for checklist completions (the `checklist-evidence` bucket
already exists with the same policy shape, just no Flutter feature uses it yet), and staff
document uploads (`staff-documents` bucket, same situation).
