-- 20260910030000_retain_pos_history and 20260910080000_retain_staff_requests
-- created RetainedPosCheck, RetainedPosLaborPunch, and RetainedStaffRequest
-- without ENABLE ROW LEVEL SECURITY, missing the rule the 20260805120000
-- Data API lockdown established for every table created after it (see
-- scripts/lint the "Lint post-lockdown migrations for RLS coverage" CI
-- check). Migrations are immutable, so this is a follow-up hardening
-- migration rather than an edit to either of those two — same pattern as
-- 20260808150000_harden_ai_usage_event_rls.
ALTER TABLE public."RetainedPosCheck" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."RetainedPosLaborPunch" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."RetainedStaffRequest" ENABLE ROW LEVEL SECURITY;

-- Supabase provides anon/authenticated roles; plain Postgres CI does not.
-- Revoke browser-facing access only when those roles exist so this migration
-- remains portable across both environments.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedPosCheck" FROM anon';
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedPosLaborPunch" FROM anon';
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedStaffRequest" FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedPosCheck" FROM authenticated';
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedPosLaborPunch" FROM authenticated';
    EXECUTE 'REVOKE ALL ON TABLE public."RetainedStaffRequest" FROM authenticated';
  END IF;
END
$$;
