# features/schedules

Shift scheduling + swaps, backed by `supabase/migrations/20261002120000_schedules_schema.sql`
and `20261002160000_shift_swaps_schema.sql`.

- `domain/shift.dart` — `Shift`, `ShiftStatus`, `ShiftSwap`, `ShiftSwapStatus`.
- `data/schedules_repository.dart` — `SchedulesRepository` interface + Supabase
  implementation: `fetchShiftsForVenue`, `createShift`, `deleteShift`, plus
  `fetchSwapsForVenue`/`requestSwap`/`acceptSwap`/`cancelSwap`/`declineSwap`.
- `application/schedules_providers.dart` — repository + shifts/swaps-for-venue providers.
- `presentation/schedule_list_screen.dart` — routed at `/schedules`: lists shifts for the
  active venue (every venue member can view; only a manager tier can create/delete, per RLS),
  with a manual "Add shift" dialog and a "Suggest coverage" action that calls
  `AiRepository.suggestScheduling` and turns each suggestion into a prefilled "Add shift"
  dialog — the suggestion is never applied directly, satisfying the manual-fallback
  requirement in `features/ai/README.md` by construction.

  Removing a shift calls the server-side `remove_or_cancel_shift` RPC. Local drafts are
  deleted; shifts with POS mapping history are retained as cancelled so a later schedule
  publication can send the provider cancellation.

  Shift swaps appear as an "Open swap requests" section above the shift list. A shift's
  current assignee gets a swap icon on their own tile to request one (open to anyone, or
  targeted — targeting isn't exposed in the UI yet, only in the repository); any other venue
  member sees an Accept button on an open or offered-to-them request, and the requester sees a
  Cancel button on their own. Accepting is the only client action that changes who a shift is
  assigned to, and even that goes through a database trigger (`apply_accepted_shift_swap`) —
  the app never writes `shifts.staff_id` directly for a swap.

- `presentation/schedule_draft_screen.dart` + `domain/schedule_draft.dart` — "Draft week" (AI
  `schedule_draft`, managers only): rules + week + max hours in, a review list out. Warnings
  (overlap with existing or other ticked proposals, weekly-hours limit, approved time off, past,
  outside the week) are computed in Dart; nothing is created until "Add selected", which uses
  `createShift` per shift with venue-clock conversion; a refused shift keeps its line and its tick.

**Not implemented yet:** any notion of a staff member seeing only their own shifts — every
venue member currently sees the whole schedule, same breadth as `features/tasks`.
