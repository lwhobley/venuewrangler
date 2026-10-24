# features/schedules

Shift scheduling + swaps, backed by `supabase/migrations/20261002120000_schedules_schema.sql`
and `20261002160000_shift_swaps_schema.sql`.

- `domain/shift.dart` — `Shift`, `ShiftStatus`, `ShiftSwap`, `ShiftSwapStatus`.
- `domain/shift_labels.dart` — how a shift is named to people ("Thu Oct 22 · Server · patio",
  "4:30 PM – 10:30 PM") and `overlappingShiftsFor` (double-booking check).
- `domain/coverage_request.dart` — the text and roster keys sent with "Suggest coverage", and
  mapping a suggestion back to a roster member.
- `data/schedules_repository.dart` — `SchedulesRepository` interface + Supabase
  implementation: `fetchShiftsForVenue`, `createShift`, `updateShift`, `deleteShift`,
  `watchScheduleChanges` (realtime), plus
  `fetchSwapsForVenue`/`requestSwap`/`claimSwap`/`unclaimShiftSwap` (taker withdraws a claimed swap)/`approveSwap`/`cancelSwap`/`declineSwap`.
- `application/schedules_providers.dart` — repository + shifts/swaps-for-venue providers, and
  `scheduleLiveUpdatesProvider`, which reloads both on realtime changes while a schedule
  screen watches it.
- `presentation/schedule_list_screen.dart` — routed at `/schedules`: lists shifts for the
  active venue (every venue member can view; only a manager tier can create/delete, per RLS),
  with a manual "Add shift" dialog and a "Suggest coverage" action that calls
  `AiRepository.suggestScheduling` and turns each suggestion into a prefilled "Add shift"
  dialog — the suggestion is never applied directly, satisfying the manual-fallback
  requirement in `features/ai/README.md` by construction.

  Removing a shift calls the server-side `remove_or_cancel_shift` RPC. Local drafts are
  deleted; shifts with POS mapping history are retained as cancelled so a later schedule
  publication can send the provider cancellation.

  Shift swaps appear as a "Shift swaps" section above the shift list, each naming the shift
  (day, time, role and section) and who offered it. A shift's current assignee gets a swap
  icon on their own tile to request one (open to anyone, or targeted — targeting isn't exposed
  in the UI yet, only in the repository). Swaps are manager-approved
  (`20261022120002_manager_approved_swaps.sql`): a teammate taps **Take shift**, confirms
  "Take Ingrid's Thu Oct 22 Server shift, 4:30 PM – 10:30 PM?" (with a warning and "Take shift
  anyway" if they already work then), and the swap becomes *claimed*; a manager then taps
  **Approve for <name>**, which gives the shift to that teammate — never to the manager. A
  manager can also Decline, or deliberately "Take it myself". The database refuses a take or
  approval that would double-book unless the confirm step passed `allowOverlap`. The app never
  writes `shifts.staff_id` directly for a swap; `apply_accepted_shift_swap` does.

  Suggest coverage sends the manager's text plus today's venue date and the roster as short
  keys (`staff_1`…, never user ids); each suggestion names the matched person and Add opens
  the dialog with that person, role and venue-local times filled in. The Add shift and
  Suggest dialogs save/run from inside the dialog and keep what was typed on failure.

- `presentation/schedule_timeline_screen.dart` — the board. It reloads on realtime changes,
  app resume and the reload button. A save sends only the fields that changed, filtered on the
  shift's `version` (`20261022120001_shift_versions_and_realtime.sql`); if someone changed the
  shift first it fails with `StaleShiftException`, the board reloads and says so, instead of
  writing old values back (e.g. undoing an approved swap). The add/edit sheet saves from
  inside and stays open with the error on failure.

- `presentation/schedule_draft_screen.dart` + `domain/schedule_draft.dart` — "Draft week" (AI
  `schedule_draft`, managers only): rules + week + max hours in, a review list out. Warnings
  (overlap with existing or other ticked proposals, weekly-hours limit, approved time off, past,
  outside the week) are computed in Dart; nothing is created until "Add selected", which uses
  `createShift` per shift with venue-clock conversion; a refused shift keeps its line and its tick.

Both schedule screens link to Requests (`/staff-requests`) for time off and drop/pick-up.

**Not implemented yet:** any notion of a staff member seeing only their own shifts — every
venue member currently sees the whole schedule, same breadth as `features/tasks`.
