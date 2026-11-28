-- Restores the previous search_path on is_safe_storage_deletion_path.
alter function app_hidden.is_safe_storage_deletion_path(text, text) set search_path = public;
