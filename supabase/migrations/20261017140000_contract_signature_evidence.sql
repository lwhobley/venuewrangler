-- Contract signing evidence (audit BL-03). Managers could write client_signature_name /
-- client_signature_date and move a contract to 'fully_signed' with a plain UPDATE, leaving no
-- evidence of who recorded what, when, or which terms were agreed. Now:
--
--   * 'partially_signed' / 'fully_signed' and the signature columns can only be set through
--     record_contract_signature(), which snapshots a SHA-256 of the contract terms, the signer
--     name, who recorded it, when, and the request's IP/user agent into an immutable-by-clients
--     event row (contract_signature_events) and writes an audit_log entry;
--   * once a contract is partially/fully signed its terms are frozen (status may only move on to
--     'disputed' or 'cancelled'), so the stored hash always describes what exists.
--
-- This records a manager attesting that the client signed (offline or in person). A client-facing
-- signing page would add the client's own IP/consent trail on top of the same table.

create table public.contract_signature_events (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.crm_contracts (id) on delete cascade,
  organization_id uuid not null,
  venue_id uuid not null,
  signer_name text not null check (char_length(signer_name) between 2 and 120),
  signer_role text not null default 'client' check (signer_role in ('client', 'venue')),
  method text not null default 'manager_attested' check (method in ('manager_attested')),
  resulting_status text not null check (resulting_status in ('partially_signed', 'fully_signed')),
  note text check (note is null or char_length(note) <= 500),
  content_sha256 text not null check (char_length(content_sha256) = 64),
  recorded_by uuid references auth.users (id) on delete set null,
  recorded_at timestamptz not null default now(),
  client_ip text,
  user_agent text
);
create index contract_signature_events_contract_idx on public.contract_signature_events (contract_id, recorded_at);

alter table public.contract_signature_events enable row level security;
alter table public.contract_signature_events force row level security;
revoke all on public.contract_signature_events from public, anon, authenticated;
grant select on public.contract_signature_events to authenticated;

create policy contract_signature_events_select on public.contract_signature_events
  for select to authenticated
  using (app_hidden.has_venue_role(
    venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ));

-- Direct writes to signature state, and edits to signed terms, are refused.
create or replace function app_hidden.guard_contract_signature()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_signing boolean := coalesce(current_setting('app.contract_signing', true), '') = 'on';
  v_terms_old jsonb;
  v_terms_new jsonb;
begin
  if app_hidden.account_deletion_in_progress() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if not v_signing and (
      new.status in ('partially_signed', 'fully_signed')
      or new.client_signature_name is not null
      or new.client_signature_date is not null
    ) then
      raise exception 'contracts are signed through record_contract_signature' using errcode = '42501';
    end if;
    return new;
  end if;

  if not v_signing then
    if new.client_signature_name is distinct from old.client_signature_name
       or new.client_signature_date is distinct from old.client_signature_date
       or (new.status in ('partially_signed', 'fully_signed') and new.status is distinct from old.status) then
      raise exception 'contracts are signed through record_contract_signature' using errcode = '42501';
    end if;

    if old.status = 'fully_signed' and new.status not in ('fully_signed', 'disputed', 'cancelled') then
      raise exception 'a fully signed contract can only be disputed or cancelled' using errcode = '42501';
    end if;

    if old.status in ('partially_signed', 'fully_signed') then
      v_terms_old := to_jsonb(old) - 'status' - 'updated_at';
      v_terms_new := to_jsonb(new) - 'status' - 'updated_at';
      if v_terms_old is distinct from v_terms_new then
        raise exception 'the terms of a signed contract cannot be changed' using errcode = '42501';
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists a_guard_contract_signature on public.crm_contracts;
create trigger a_guard_contract_signature
  before insert or update on public.crm_contracts
  for each row execute function app_hidden.guard_contract_signature();

create or replace function public.record_contract_signature(
  p_contract_id uuid,
  p_signer_name text,
  p_fully_signed boolean default true,
  p_note text default null
)
returns public.crm_contracts
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contract public.crm_contracts;
  v_name text := trim(coalesce(p_signer_name, ''));
  v_status text := case when coalesce(p_fully_signed, true) then 'fully_signed' else 'partially_signed' end;
  v_hash text;
  v_ip text;
  v_agent text;
  v_headers jsonb;
begin
  select * into v_contract from public.crm_contracts where id = p_contract_id for update;
  if not found then
    raise exception 'contract not found' using errcode = 'P0002';
  end if;

  if auth.uid() is null or not app_hidden.has_venue_role(
    v_contract.venue_id, array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_contract.status not in ('draft', 'sent', 'viewed', 'partially_signed') then
    raise exception 'contract is % and cannot be signed', v_contract.status using errcode = 'P0001';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'signer name must be 2-120 characters' using errcode = '22023';
  end if;

  v_hash := encode(
    sha256(convert_to((to_jsonb(v_contract) - 'status' - 'updated_at' - 'client_signature_name' - 'client_signature_date')::text, 'UTF8')),
    'hex'
  );

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_ip := left(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1), 64);
  v_agent := left(coalesce(v_headers ->> 'user-agent', ''), 300);

  perform set_config('app.contract_signing', 'on', true);
  update public.crm_contracts
     set client_signature_name = v_name,
         client_signature_date = now(),
         status = v_status
   where id = v_contract.id
  returning * into v_contract;
  perform set_config('app.contract_signing', 'off', true);

  insert into public.contract_signature_events (
    contract_id, organization_id, venue_id, signer_name, resulting_status, note, content_sha256,
    recorded_by, client_ip, user_agent
  ) values (
    v_contract.id, v_contract.organization_id, v_contract.venue_id, v_name, v_status,
    nullif(trim(coalesce(p_note, '')), ''), v_hash, auth.uid(), nullif(v_ip, ''), nullif(v_agent, '')
  );

  perform app_hidden.audit_event(
    v_contract.organization_id, v_contract.venue_id, 'contract.signature_recorded', 'crm_contracts', v_contract.id,
    jsonb_build_object('status', v_status, 'content_sha256', v_hash)
  );

  return v_contract;
end;
$$;

revoke all on function public.record_contract_signature(uuid, text, boolean, text) from public, anon;
grant execute on function public.record_contract_signature(uuid, text, boolean, text) to authenticated;
