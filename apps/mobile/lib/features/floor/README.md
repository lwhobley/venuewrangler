# Floor Management Feature

Port of legacy NestJS `floor` module to native Supabase + Flutter with PostgreSQL transactional guarantees and Realtime live synchronization.

## Architecture

- **Database**:
  - `public.floor_plans`: venue-scoped visual layout boundaries (width, height, background image, active toggle).
  - `public.floor_tables`: venue and plan-scoped tables with coordinate positions (`x`, `y`, `width`, `height`, `rotation`), shapes (`round`, `square`, `rect`, `booth`), statuses (`available`, `seated`, `dirty`, `reserved`, `held`, `out_of_service`), capacity, and `merge_group_id`.
  - `public.floor_table_assignments`: assignment records linking tables to reservations and waitlist entries with hold times (`starts_at`, `ends_at`) and hold types (`reserved`, `held`, `seated`).
- **Transactional Guarantees & Advisory Locking**:
  - `public.merge_floor_tables`: executes sorted table-level advisory transaction locks (`pg_advisory_xact_lock`), validates venue ownership, and assigns a shared `merge_group_id` atomically.
  - `public.split_floor_tables`: acquires sorted advisory locks and clears the `merge_group_id`.
  - `public.assign_tables_to_reservation`: acquires advisory locks, inserts `floor_table_assignments`, and updates table statuses in a single atomic transaction.
  - `public.update_floor_table_status`: acquires advisory lock on table and updates status with timestamp tracking.
- **Realtime Synchronization**:
  - `public.floor_tables` and `public.floor_table_assignments` are registered with the `supabase_realtime` publication.
  - The Flutter client subscribes to Postgres Changes via `streamFloorTables` for live updates across host and server devices.
- **Security & RLS**:
  - `FORCE ROW LEVEL SECURITY` on all floor tables.
  - Venue members can view floor layouts and tables.
  - Managers can create and update floor plans.
  - Staff and managers can update table states, merge, split, and assign tables.
