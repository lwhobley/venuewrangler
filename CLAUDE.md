This project is a Flutter mobile app (`apps/mobile`) backed directly by
Supabase (Postgres, Auth, Storage). Firebase is used only for Android push.

Backend logic lives in Supabase migrations (`supabase/migrations`), enforced
via RLS policies and `SECURITY DEFINER` functions. Prefer the existing
Riverpod providers and repository classes under
`apps/mobile/lib/features/*/data` when adding or modifying data-backed app
features.

The marketing site (`packages/marketing`, `site/`) is a separate static site
and is unaffected by the Flutter app.
