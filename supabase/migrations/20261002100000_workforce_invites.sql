-- Phase 3 feature: workforce (staff roster + onboarding). The roster view itself needs no new
-- table — it's just memberships joined with profiles, both already readable per the
-- foundation migration's `memberships_select_org_admins`/`profiles_select_shared_scope`
-- policies. What's missing is a way to invite someone who doesn't have a membership (or even
-- an account) yet: this table records that intent so a manager/admin can track and revoke it.
-- Redemption (turning an accepted invite into a membership row) is server-mediated — deferred
-- to a future Edge Function, matching the migration plan's "invite-member Edge Function" item
-- — this migration only covers the create/view/revoke lifecycle a manager drives.
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  email text not null check (char_length(trim(email)) > 0),
  role public.app_role not null check (role in ('venue_manager', 'supervisor', 'staff')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  invited_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  unique (venue_id, email, status)
);

create index invites_venue_id_idx on public.invites (venue_id);
create index invites_organization_id_idx on public.invites (organization_id);
create index invites_email_idx on public.invites (lower(email));

-- organization_id is derived from venue_id and invited_by from the caller, same "derive,
-- don't trust" pattern as every other Phase 2/3 table — a client cannot forge either.
create or replace function app_hidden.prepare_invite_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.venues where id = new.venue_id;
  if v_org_id is null then
    raise exception 'venue % does not exist', new.venue_id;
  end if;
  new.organization_id := v_org_id;
  new.invited_by := auth.uid();
  new.email := lower(trim(new.email));
  return new;
end;
$$;

create trigger prepare_invite_insert
  before insert on public.invites
  for each row execute function app_hidden.prepare_invite_insert();

-- The only update a client may ever make is pending -> revoked (see the trigger below and
-- the update policy's WITH CHECK); acceptance is set by the future redemption Edge Function
-- using the service role, which bypasses RLS entirely.
create or replace function app_hidden.enforce_invite_revoke_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status <> 'pending' or new.status <> 'revoked' then
    raise exception 'invites can only be moved from pending to revoked by a client' using errcode = '42501';
  end if;
  if new.organization_id is distinct from old.organization_id
    or new.venue_id is distinct from old.venue_id
    or new.email is distinct from old.email
    or new.role is distinct from old.role
    or new.invited_by is distinct from old.invited_by
    or new.created_at is distinct from old.created_at
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'only an invite''s status may be changed, and only to revoked' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger enforce_invite_revoke_only
  before update on public.invites
  for each row execute function app_hidden.enforce_invite_revoke_only();

alter table public.invites enable row level security;
alter table public.invites force row level security;

-- Only org admins/owners and the inviting venue's manager tier may see or manage invites —
-- an invite's target email is PII that should not be broadly readable, unlike a membership
-- row (which is just "a known user has a role").
create policy invites_select_managers on public.invites
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy invites_insert_managers on public.invites
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy invites_update_managers on public.invites
  for update to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  )
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );
