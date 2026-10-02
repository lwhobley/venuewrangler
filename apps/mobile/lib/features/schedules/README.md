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

  Shift swaps appear as an "Open swap requests" section above the shift list. A shift's
  current assignee gets a swap icon on their own tile to request one (open to anyone, or
  targeted — targeting isn't exposed in the UI yet, only in the repository); any other venue
  member sees an Accept button on an open or offered-to-them request, and the requester sees a
  Cancel button on their own. Accepting is the only client action that changes who a shift is
  assigned to, and even that goes through a database trigger (`apply_accepted_shift_swap`) —
  the app never writes `shifts.staff_id` directly for a swap.

**Not implemented yet:** any notion of a staff member seeing only their own shifts — every
venue member currently sees the whole schedule, same breadth as `features/tasks`.
