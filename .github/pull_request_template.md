## Summary

<!-- What changes and why. Link the issue or audit finding (for example A-04, O-06). -->

## Type of change

- [ ] Bug fix
- [ ] Feature
- [ ] Database migration / RLS change
- [ ] Edge Function change
- [ ] CI / infrastructure / configuration
- [ ] Documentation / policy

## Security checklist

- [ ] No secrets, tokens, keys, service-account JSON, `.env` files or real customer data in this diff, commit messages or screenshots
- [ ] New or changed tables have RLS enabled, policies `to authenticated`, and a pgTAP test in `supabase/tests/database/`
- [ ] New `SECURITY DEFINER` functions set `search_path`, check the caller's membership/role, and have `EXECUTE` revoked from `public`/`anon` where appropriate
- [ ] Edge Functions that set `verify_jwt = false` authenticate the caller another way (signature, shared secret, signed state) and say so in a comment
- [ ] Inputs are validated server-side; no string-built SQL or PostgREST filters from user input
- [ ] New personal data (staff, guests, locations, photos) is listed in the privacy policy and covered by a retention rule
- [ ] New third-party service or SDK is added to the subprocessor list (`docs/privacy-policy.md`, `site/privacy/index.html`, `docs/production-operations.md`)
- [ ] New or changed dependency: lockfile updated, `npm audit --omit=dev --audit-level=high` clean, `deno.lock` updated for Edge Functions
- [ ] Workflow changes keep SHA-pinned actions, least-privilege `permissions:`, and pass user input through `env:` (never `${{ }}` inside `run:`)
- [ ] Production-affecting change has a rollback or forward-fix plan (see `docs/production-operations.md`)

## Testing

<!-- Commands run (npm test, flutter test, pg_prove, deno test) and manual checks. -->

## Deployment notes

<!-- Migrations to apply by hand, secrets to set, environments to configure, order of operations. -->
