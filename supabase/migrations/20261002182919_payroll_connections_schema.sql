-- Phase 3 feature: payroll push integrations (Square/QuickBooks/Gusto). Venue-scoped, same
-- "derive, don't trust" shape as the other Phase 2/3 tables.
--
-- The encrypted OAuth token columns must NEVER reach a client, even a legitimately
-- authorized venue_manager+ who is allowed to see that a connection *exists*. RLS alone
-- cannot express that (it is row-, not column-, granular), so this migration layers a
-- Postgres column-level GRANT on top of the usual RLS SELECT policy: `authenticated` is
-- granted SELECT on only the non-secret columns, and the live project's broad default
-- table-level grant (see supabase/tests/ci_grants_stub.sql's note on this) is first revoked
-- so the narrower grant actually takes effect instead of being shadowed by it.
create table public.payroll_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  provider text not null check (provider in ('square', 'quickbooks', 'gusto')),
  status text not null default 'disconnected' check (status in ('disconnected', 'connected', 'error')),
  external_account_id text,
  encrypted_access_token text,
  encrypted_refresh_token text,
  token_expires_at timestamptz,
  last_error text,
  connected_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, provider)
);

create index payroll_connections_venue_id_idx on public.payroll_connections (venue_id);
create index payroll_connections_organization_id_idx on public.payroll_connections (organization_id);

create or replace function app_hidden.prepare_payroll_connection_insert()
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
  return new;
end;
$$;

create trigger prepare_payroll_connection_insert
  before insert on public.payroll_connections
  for each row execute function app_hidden.prepare_payroll_connection_insert();

create or replace function app_hidden.sync_payroll_connection_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger sync_payroll_connection_update
  before update on public.payroll_connections
  for each row execute function app_hidden.sync_payroll_connection_update();

alter table public.payroll_connections enable row level security;
alter table public.payroll_connections force row level security;

-- Row-level gate: a venue's manager tier may see that a connection exists and its
-- (non-secret) status. No insert/update/delete policy exists for `authenticated` at all —
-- every write (connect/disconnect/token refresh) goes through the `{provider}-oauth` Edge
-- Functions using the service role, which is also the only thing that ever decrypts a token.
create policy payroll_connections_select_managers on public.payroll_connections
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Column-level gate: even a manager who passes the row-level policy above can never select
-- the encrypted token columns — only the service role (which bypasses grants, same as it
-- bypasses RLS) can read them, inside an Edge Function, never returned to a client.
revoke all on public.payroll_connections from authenticated;
grant select (
  id, organization_id, venue_id, provider, status, external_account_id,
  token_expires_at, last_error, connected_by, created_at, updated_at
) on public.payroll_connections to authenticated;
