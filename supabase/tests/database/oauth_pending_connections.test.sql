-- pgTAP tests for public.oauth_pending_connections (supabase/migrations/20261017120000).
-- The table holds ENCRYPTED provider tokens between the provider callback and the app's
-- authenticated completion call. No client role may ever see or write it; only the service role
-- (the {provider}-oauth Edge Functions) can. Same fixture style as payroll_connections_rls.

begin;
select plan(13);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000c1', 'oauth-manager@example.com'),
  ('00000000-0000-0000-0000-0000000000c2', 'oauth-other@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-0000000000c1', 'OAuth Org');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'OAuth Venue');

-- Seeded as table owner, the way an Edge Function's service-role client would write it.
insert into public.oauth_pending_connections
  (id, state_nonce, user_id, venue_id, organization_id, provider, external_account_id,
   encrypted_access_token, encrypted_refresh_token)
values
  ('30000000-0000-0000-0000-0000000000c1', '40000000-0000-0000-0000-0000000000c1',
   '00000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c1',
   '10000000-0000-0000-0000-0000000000c1', 'square', 'merchant_1',
   'v1.aXY=.Y3Q=', 'v1.aXY=.cmVm');

-- ---------------------------------------------------------------------------
-- structure
-- ---------------------------------------------------------------------------

select is(
  (select relrowsecurity and relforcerowsecurity from pg_class
   where oid = 'public.oauth_pending_connections'::regclass),
  true,
  'row level security is enabled and forced'
);

select is(
  (select count(*)::int from pg_policies
   where schemaname = 'public' and tablename = 'oauth_pending_connections'),
  0,
  'there are no client policies at all'
);

select ok(
  (select expires_at > now() + interval '9 minutes' and expires_at <= now() + interval '10 minutes 5 seconds'
   from public.oauth_pending_connections where id = '30000000-0000-0000-0000-0000000000c1'),
  'expires_at defaults to roughly ten minutes out'
);

-- ---------------------------------------------------------------------------
-- authenticated: no select, no insert, no update (even for the row's own user)
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-0000000000c1';

select throws_ok(
  $$ select count(*) from public.oauth_pending_connections $$,
  '42501',
  null,
  'authenticated cannot select pending connections, even for their own user'
);

select throws_ok(
  $$ select encrypted_access_token from public.oauth_pending_connections $$,
  '42501',
  null,
  'authenticated cannot select the encrypted token columns'
);

select throws_ok(
  $$ insert into public.oauth_pending_connections
       (state_nonce, user_id, venue_id, organization_id, provider, encrypted_access_token)
     values ('40000000-0000-0000-0000-0000000000c9', '00000000-0000-0000-0000-0000000000c1',
             '20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1',
             'square', 'forged') $$,
  '42501',
  null,
  'authenticated cannot forge a pending connection'
);

select throws_ok(
  $$ update public.oauth_pending_connections set consumed_at = now() $$,
  '42501',
  null,
  'authenticated cannot consume a pending connection'
);

-- ---------------------------------------------------------------------------
-- anon
-- ---------------------------------------------------------------------------

reset role;
set local role anon;

select throws_ok(
  $$ select count(*) from public.oauth_pending_connections $$,
  '42501',
  null,
  'anon cannot select pending connections'
);

-- ---------------------------------------------------------------------------
-- service_role
-- ---------------------------------------------------------------------------

reset role;
set local role service_role;

select is(
  (select count(*)::int from public.oauth_pending_connections),
  1,
  'service_role can read pending connections'
);

select lives_ok(
  $$ insert into public.oauth_pending_connections
       (state_nonce, user_id, venue_id, organization_id, provider, encrypted_access_token, created_at)
     values ('40000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000c2',
             '20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1',
             'gusto', 'v1.aXY=.Y3Q=', now() - interval '26 hours') $$,
  'service_role can insert pending connections'
);

select throws_ok(
  $$ insert into public.oauth_pending_connections
       (state_nonce, user_id, venue_id, organization_id, provider, encrypted_access_token)
     values ('40000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1',
             '20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1',
             'square', 'v1.replayed') $$,
  '23505',
  null,
  'a signed state can be redeemed once: a replayed state_nonce is rejected'
);

select lives_ok(
  $$ update public.oauth_pending_connections set consumed_at = now()
     where id = '30000000-0000-0000-0000-0000000000c1' and consumed_at is null $$,
  'service_role can atomically consume a pending connection'
);

-- ---------------------------------------------------------------------------
-- cleanup (runs as the owner; the 26-hour-old row above is stale, the other is not)
-- ---------------------------------------------------------------------------

reset role;

select is(
  app_hidden.cleanup_oauth_pending_connections(),
  1::bigint,
  'cleanup deletes only rows older than a day'
);

select * from finish();
rollback;
