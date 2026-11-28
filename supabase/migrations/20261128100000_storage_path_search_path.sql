-- Review fixes on main @ e57a02a.

-- E09: is_safe_storage_deletion_path was the last app_hidden function still resolving names
-- through `public`. It only uses built-in operators (~, ~*, like), which live in pg_catalog and
-- are always searched, so an empty search_path changes nothing about its behaviour.
alter function app_hidden.is_safe_storage_deletion_path(text, text) set search_path = '';
