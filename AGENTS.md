The app is Flutter, in `apps/mobile`, using Riverpod, GoRouter, and Supabase
(Auth, Postgres, Storage). Firebase is used only for Android push.

Implement new product features in `apps/mobile`, with server-side
authorization enforced in Supabase migrations (`supabase/migrations`) and the
existing repository classes under `apps/mobile/lib/features/*/data`.
