-- Remove live drift: debug helpers present in production but in no migration,
-- flagged by the Supabase security advisor for mutable search_path.
drop function if exists app_hidden.test_returns_table();
drop function if exists app_hidden.test_nested_exception();
