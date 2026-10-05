-- Phase 3 feature: invite redemption. Extends the foundation migration's
-- `app_hidden.handle_new_user()` trigger (already fired `after insert on auth.users` to create
-- a profiles row) to also turn any pending invite matching the new user's email into a real
-- membership, atomically within the same transaction as account creation — no separate
-- Edge Function or auth webhook needed, and no window where a signed-up user's invite sits
-- unredeemed. `invites` was explicitly scoped to the create/view/revoke lifecycle in
-- workforce_invites.sql and deferred redemption to "a future Edge Function"; this
-- trigger-based approach turned out simpler and more reliable than a webhook once actually
-- building it, so it supersedes that plan without needing to touch invites' RLS at all.
-- workforce_invites.sql's enforce_invite_revoke_only trigger only ever allowed
-- pending -> revoked, written before redemption existed. handle_new_user (below) needs to
-- move an invite pending -> accepted, and that trigger fires for every update regardless of
-- caller (it cannot tell "the signup trigger" apart from "a client's own update"), so it must
-- now allow both transitions. This does let a venue_manager mark an invite accepted directly
-- through their own update policy without the invitee ever having signed up — a data-
-- integrity annoyance (an invite shown as accepted with no corresponding membership), not a
-- privilege escalation: that path creates no membership row and grants no access.
create or replace function app_hidden.enforce_invite_revoke_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status <> 'pending' or new.status not in ('revoked', 'accepted') then
    raise exception 'invites can only move from pending to revoked or accepted' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.invited_by is distinct from old.invited_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'only an invite''s status may be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function app_hidden.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite record;
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;

  for v_invite in
    select * from public.invites
    where email = lower(new.email)
      and status = 'pending'
      and expires_at > now()
  loop
    insert into public.memberships (user_id, organization_id, venue_id, role, created_by)
    values (new.id, v_invite.organization_id, v_invite.venue_id, v_invite.role, v_invite.invited_by)
    on conflict (user_id, organization_id, venue_id) do nothing;

    update public.invites set status = 'accepted' where id = v_invite.id;
  end loop;

  return new;
end;
$$;
