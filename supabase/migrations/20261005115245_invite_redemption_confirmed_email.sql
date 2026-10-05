-- Fix MEDIUM: invites were redeemed at signup before email confirmation.
-- Anyone knowing an invitee's email could pre-register it, consume the invite and block
-- the real person (and if confirmations were ever disabled, privilege escalation).
-- Redeem only once the email is confirmed, on both insert (already-confirmed, e.g.
-- OAuth with verified email) and update-of-confirmation (magic-link confirmation later).

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

  -- Only redeem invites once the address is verified.
  if new.email_confirmed_at is null then
    return new;
  end if;

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

drop trigger if exists on_auth_user_created on auth.users;
-- Fire on insert AND when the confirmation timestamp gets set.
create trigger on_auth_user_created
  after insert or update of email_confirmed_at on auth.users
  for each row execute function app_hidden.handle_new_user();
