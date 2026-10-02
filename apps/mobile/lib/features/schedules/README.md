# features/schedules

Shift scheduling, backed by `supabase/migrations/20261002120000_schedules_schema.sql`.

- `domain/shift.dart` — `Shift`, `ShiftStatus`.
- `data/schedules_repository.dart` — `SchedulesRepository` interface + Supabase
  implementation: `fetchShiftsForVenue`, `createShift`, `deleteShift`.
- `application/schedules_providers.dart` — repository + shifts-for-venue provider.
- `presentation/schedule_list_screen.dart` — routed at `/schedules`: lists shifts for the
  active venue (every venue member can view; only a manager tier can create/delete, per RLS),
  with a manual "Add shift" dialog and a "Suggest coverage" action that calls
  `AiRepository.suggestScheduling` and turns each suggestion into a prefilled "Add shift"
  dialog — the suggestion is never applied directly, satisfying the manual-fallback
  requirement in `features/ai/README.md` by construction.

**Not implemented yet:** shift swaps (the migration plan's `shift_swaps` table/flow) and any
notion of a staff member seeing only their own shifts — every venue member currently sees the
whole schedule, same breadth as `features/tasks`.
