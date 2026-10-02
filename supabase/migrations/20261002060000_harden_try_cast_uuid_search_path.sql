-- Hardening follow-up to 20261002040000_storage_buckets.sql, caught by Supabase's own
-- security linter (function_search_path_mutable) after applying migrations to a real
-- project: app_hidden.try_cast_uuid was missing `set search_path`, unlike every other
-- app_hidden function. It isn't itself SECURITY DEFINER, but it's called from
-- app_hidden.storage_path_venue_id, which is — a mutable search_path on a function reachable
-- from a SECURITY DEFINER context is exactly the shape of bug search_path pinning exists to
-- prevent, even though this particular function's body doesn't currently reference anything
-- search_path-sensitive. Fixed as a new migration, not an edit to the original one, matching
-- this repo's convention for hardening something already shipped (see the reference
-- implementation's own "harden_*" migrations, cited in .github/workflows/api-ci.yml).

alter function app_hidden.try_cast_uuid(text) set search_path = public;
