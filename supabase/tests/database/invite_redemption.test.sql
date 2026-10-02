-- pgTAP tests for invite redemption (supabase/migrations/20261002150000). Exercises
-- app_hidden.handle_new_user()'s extended logic: a new auth.users row with a matching email
-- should atomically become a membership, with the invite marked accepted.

begin;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager');

-- Seeded as table owner (bypasses RLS), the way the manager-facing invite dialog's insert
-- would have created these. The expired row sets expires_at directly on insert rather than
-- via a later UPDATE, since enforce_invite_revoke_only (see workforce_invites.sql) forbids
-- changing expires_at on any update, by design — insert is unaffected.
insert into public.invites (id, venue_id, email, role, invited_by) values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-0000000000a1', 'new-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-0000000000a1', 'revoked-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004');

insert into public.invites (id, venue_id, email, role, invited_by, expires_at) values
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-0000000000a1', 'expired-hire@example.com', 'staff', '00000000-0000-0000-0000-000000000004', now() - interval '1 day');

update public.invites set status = 'revoked' where id = '30000000-0000-0000-0000-000000000002';

-- ---------------------------------------------------------------------------
-- signup matching a pending, unexpired invite
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000010', 'New-Hire@Example.com');

select is(
  (select role from public.memberships where user_id = '00000000-0000-0000-0000-000000000010'),
  'staff',
  'signing up with an invited (case-insensitive) email creates the matching membership'
);

select is(
  (select venue_id from public.memberships where user_id = '00000000-0000-0000-0000-000000000010'),
  '20000000-0000-0000-0000-0000000000a1'::uuid,
  'the membership is scoped to the invite''s venue'
);

select is(
  (select status from public.invites where id = '30000000-0000-0000-0000-000000000001'),
  'accepted',
  'the invite is marked accepted'
);

select is(
  (select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-000000000010'),
  1,
  'the pre-existing profile-creation behavior still happens alongside invite redemption'
);

-- ---------------------------------------------------------------------------
-- signup with no matching invite
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000011', 'nobody-invited@example.com');

select is(
  (select count(*)::int from public.memberships where user_id = '00000000-0000-0000-0000-000000000011'),
  0,
  'signing up with no matching invite creates no membership'
);

-- ---------------------------------------------------------------------------
-- a revoked invite is never redeemed
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000012', 'revoked-hire@example.com');

select is(
  (select count(*)::int from public.memberships where user_id = '00000000-0000-0000-0000-000000000012'),
  0,
  'a revoked invite is not redeemed on signup'
);

-- ---------------------------------------------------------------------------
-- an expired invite is never redeemed
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000013', 'expired-hire@example.com');

select is(
  (select count(*)::int from public.memberships where user_id = '00000000-0000-0000-0000-000000000013'),
  0,
  'an expired invite is not redeemed on signup'
);

select * from finish();
rollback;
