-- VW-A16 regression: 20260910040000_join_request_allaccess and
-- 20260910060000_join_request_event_venueid both used CREATE OR REPLACE
-- FUNCTION on these four functions. Contrary to the comment on the original
-- 20260902120000 fix ("pinning inside the function definition survives
-- future CREATE OR REPLACE"), a search_path pin applied via a separate
-- ALTER FUNCTION statement is NOT preserved by a later CREATE OR REPLACE of
-- the same function — proconfig resets unless the new CREATE statement
-- itself includes a SET clause. The "Verify critical constraints" CI check
-- caught all four with proconfig back to NULL. Re-pin them the same way
-- 20260902120000 did.
ALTER FUNCTION public.request_join_workplace(TEXT, TEXT)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.approve_join_request(TEXT, TEXT)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.cancel_join_request(TEXT, TEXT)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.reject_join_request(TEXT, TEXT, TEXT)
  SET search_path = public, pg_temp;
