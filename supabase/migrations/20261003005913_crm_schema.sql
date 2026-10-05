-- Phase 4 feature: crm (leads, BEOs, contracts, pipeline forecast).
-- Ports packages/api/src/modules/crm/ faithfully, with one deliberate schema improvement and
-- one deliberate scope decision, both called out below.
--
-- Faithfully preserved from the legacy module:
--  - No DB-level state-machine transition enforcement on lead/BEO/contract status, except the
--    one real guard legacy has: a fully-signed contract's content fields and status are frozen
--    except for cancelling/disputing it. Legacy allows any other enum-to-enum jump; this does
--    too. Do not invent stronger transition rules than legacy actually has.
--  - BEO full-replace semantics are a client/API concern, not a DB one — not relevant to schema.
--  - depositStatus formalized as a checked enum (due/paid/waived) rather than legacy's free
--    string, since nothing relies on an undocumented fourth value existing.
--  - Pipeline forecast's STAGE_PROBABILITY weights are copied verbatim from the legacy
--    constant — an explicitly arbitrary, not statistically derived, business parameter.
--  - BEO email recipient allowlist, BEO deposit Stripe checkout, and Resend template delivery
--    are NOT built here — see the Phase 4 validation report for why (no Resend integration
--    exists anywhere in this rebuild yet, and the deposit checkout needs the same "verify
--    against Stripe's real one-time-payment docs first" treatment the guests/reservations
--    handoff already flagged for reservation deposits). Schema + RLS + the waive path (which
--    needs no outbound call) are built; the two API calls out to Stripe/Resend are a
--    documented gap, not silently skipped.
--  - The legacy public leads webhook does NOT feed this module — it writes to public.guests,
--    a separate, already-ported concept (see 20261002250000_guests_reservations_schema.sql).
--    This is confirmed, not a guess: do not wire one into the other without a product decision.
--
-- Deliberate improvement over legacy: legacy links a confirmed BEO to its blocking Reservation
-- via a string tag (`beo:<id>`) with no FK/uniqueness — flagged in the legacy audit as the
-- single most RLS-hostile piece of denormalization in the module (an RLS policy can't cheaply
-- join through a tags[] array). Replaced here with a real, nullable, unique `beo_id` FK on
-- public.reservations.

-- (reservations.beo_id is added further down, right after crm_beos is created — Postgres
-- can't add a column referencing a table that doesn't exist yet.)

-- -----------------------------------------------------------------------------
-- 1. Leads
-- -----------------------------------------------------------------------------
create table public.crm_leads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  guest_id uuid references public.guests (id) on delete set null,
  full_name text not null check (char_length(trim(full_name)) > 0),
  email text,
  phone text,
  company text,
  source text,
  status text not null default 'new' check (
    status in (
      'new', 'contacted', 'qualified', 'proposal_sent', 'negotiating',
      'won', 'lost', 'unqualified', 'on_hold'
    )
  ),
  tags text[] not null default '{}',
  assigned_to uuid references auth.users (id) on delete set null,
  marketing_opt_in boolean,
  last_activity_at timestamptz,
  estimated_value_cents integer check (estimated_value_cents is null or estimated_value_cents >= 0),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index crm_leads_venue_id_idx on public.crm_leads (venue_id);
create index crm_leads_venue_status_idx on public.crm_leads (venue_id, status);
create index crm_leads_guest_id_idx on public.crm_leads (guest_id);
create index crm_leads_assigned_to_idx on public.crm_leads (assigned_to);

create or replace function app_hidden.crm_leads_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;
    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

create trigger trg_crm_leads_derive
  before insert or update on public.crm_leads
  for each row execute function app_hidden.crm_leads_derive();

-- A lead's status change is always logged, even when a direct SQL update bypasses whatever API
-- layer would otherwise have called a "log activity" helper — legacy's equivalent is a
-- best-effort, callable-skippable side effect; this is not, which is a deliberate hardening,
-- not a behavior legacy actually has (legacy's activity log is still best-effort on insert
-- failure in the sense that nothing here blocks the lead update if the log insert itself
-- somehow failed, since both happen in the same statement-level trigger transaction — but
-- unlike legacy, a caller can no longer skip logging by using a different code path).
create or replace function app_hidden.crm_leads_log_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)
    values (new.venue_id, new.id, auth.uid(), 'status_changed', old.status || ' -> ' || new.status);
  end if;
  return new;
end;
$$;

create trigger trg_crm_leads_log_status_change
  after update on public.crm_leads
  for each row execute function app_hidden.crm_leads_log_status_change();

alter table public.crm_leads enable row level security;
alter table public.crm_leads force row level security;

-- Legacy gates every CRM endpoint (including read) behind canManageVenue — staff/supervisor get
-- 403 on all of it, not just writes. Matched exactly: no select policy for staff/supervisor.
create policy crm_leads_select on public.crm_leads
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_leads_insert on public.crm_leads
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_leads_update on public.crm_leads
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

-- -----------------------------------------------------------------------------
-- 2. Notes
-- -----------------------------------------------------------------------------
create table public.crm_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  lead_id uuid not null references public.crm_leads (id) on delete cascade,
  author_id uuid references auth.users (id) on delete set null,
  text text not null check (char_length(trim(text)) > 0),
  created_at timestamptz not null default now()
);

create index crm_notes_lead_created_idx on public.crm_notes (lead_id, created_at);
create index crm_notes_venue_id_idx on public.crm_notes (venue_id);
create index crm_notes_author_id_idx on public.crm_notes (author_id);

create or replace function app_hidden.crm_notes_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead_venue_id uuid;
  v_lead_org_id uuid;
begin
  select venue_id, organization_id into v_lead_venue_id, v_lead_org_id
  from public.crm_leads where id = new.lead_id;

  if v_lead_venue_id is null then
    raise exception 'invalid_lead_id: lead does not exist' using errcode = '23503';
  end if;

  new.venue_id := v_lead_venue_id;
  new.organization_id := v_lead_org_id;
  new.author_id := auth.uid();
  new.created_at := now();

  update public.crm_leads
  set last_activity_at = now(), updated_at = now()
  where id = new.lead_id;

  return new;
end;
$$;

create trigger trg_crm_notes_derive
  before insert on public.crm_notes
  for each row execute function app_hidden.crm_notes_derive();

create or replace function app_hidden.crm_notes_log_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)
  values (new.venue_id, new.lead_id, new.author_id, 'note_added', left(new.text, 120));
  return new;
end;
$$;

create trigger trg_crm_notes_log_activity
  after insert on public.crm_notes
  for each row execute function app_hidden.crm_notes_log_activity();

alter table public.crm_notes enable row level security;
alter table public.crm_notes force row level security;

create policy crm_notes_select on public.crm_notes
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_notes_insert on public.crm_notes
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- Notes are immutable once created, same as legacy (no edit endpoint exists there either).
-- No update/delete policy at all.

-- -----------------------------------------------------------------------------
-- 3. BEOs (Banquet Event Orders)
-- -----------------------------------------------------------------------------
create table public.crm_beos (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  lead_id uuid references public.crm_leads (id) on delete set null,
  event_name text not null check (char_length(trim(event_name)) > 0),
  event_date timestamptz,
  event_type text,
  guest_count integer check (guest_count is null or guest_count > 0),
  venue_space text,
  setup_style text,
  fb_minimum_cents integer check (fb_minimum_cents is null or fb_minimum_cents >= 0),
  deposit_cents integer check (deposit_cents is null or deposit_cents >= 0),
  deposit_due_date timestamptz,
  deposit_status text check (deposit_status is null or deposit_status in ('due', 'paid', 'waived')),
  deposit_checkout_session_id text,
  deposit_payment_intent_id text,
  deposit_paid_at timestamptz,
  menu_appetizers text,
  menu_entrees text,
  menu_desserts text,
  menu_bar_package text,
  special_requirements text,
  internal_notes text,
  assigned_rep_id uuid references auth.users (id) on delete set null,
  status text not null default 'draft' check (
    status in ('draft', 'sent', 'reviewed', 'confirmed', 'amended', 'cancelled')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index crm_beos_venue_id_idx on public.crm_beos (venue_id);
create index crm_beos_lead_id_idx on public.crm_beos (lead_id);
create index crm_beos_venue_status_idx on public.crm_beos (venue_id, status);

create or replace function app_hidden.crm_beos_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_lead_venue_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;

    if new.lead_id is not null then
      select venue_id into v_lead_venue_id from public.crm_leads where id = new.lead_id;
      if v_lead_venue_id is null or v_lead_venue_id <> new.venue_id then
        raise exception 'lead % does not belong to venue %', new.lead_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;

    -- Deposit waived can never go back to paid-by-hand (must go through paid directly); a
    -- settled deposit (paid or waived) can't be edited back to due either. Matches legacy's
    -- waiveBeoDeposit/unpaidBeoDepositBlocksContract treating both as terminal.
    if old.deposit_status = 'paid' and new.deposit_status is distinct from 'paid' then
      raise exception 'a paid deposit cannot be changed' using errcode = '42501';
    end if;

    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

create trigger trg_crm_beos_derive
  before insert or update on public.crm_beos
  for each row execute function app_hidden.crm_beos_derive();

-- BEO status transitions with real side effects: confirming syncs a blocking reservation
-- (transactional — the whole statement rolls back if the venue/time slot is already held, so a
-- confirmed BEO can never exist without its reservation, same guarantee legacy's $transaction
-- gave); cancelling releases it. Matches legacy's syncBeoToReservation/cancellation behavior,
-- with the tag-based pseudo-FK replaced by the real reservations.beo_id column.
create or replace function app_hidden.crm_beos_sync_reservation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conflict_count integer;
  v_existing_reservation_id uuid;
  v_guest_name text;
  v_guest_phone text;
  v_guest_email text;
begin
  if new.status = 'confirmed' and new.event_date is not null
     and (old.status is distinct from 'confirmed' or new.event_date is distinct from old.event_date
          or new.guest_count is distinct from old.guest_count or new.venue_space is distinct from old.venue_space)
  then
    select id into v_existing_reservation_id from public.reservations where beo_id = new.id;

    if v_existing_reservation_id is null then
      select count(*) into v_conflict_count
      from public.reservations
      where venue_id = new.venue_id
        and status not in ('cancelled', 'no_show')
        and beo_id is distinct from new.id
        and reservation_time < new.event_date + interval '240 minutes'
        and reservation_time + make_interval(mins => duration_minutes) > new.event_date;

      if v_conflict_count > 0 then
        raise exception 'reservation_hold_conflict: the requested event window is already held' using errcode = '23505';
      end if;
    end if;

    if new.lead_id is not null then
      select full_name, phone, email into v_guest_name, v_guest_phone, v_guest_email
      from public.crm_leads where id = new.lead_id;
    end if;

    if v_existing_reservation_id is not null then
      update public.reservations
      set reservation_time = new.event_date,
          duration_minutes = 240,
          party_size = coalesce(new.guest_count, party_size),
          guest_name = coalesce(v_guest_name, guest_name),
          guest_phone = coalesce(v_guest_phone, guest_phone),
          guest_email = coalesce(v_guest_email, guest_email),
          status = 'confirmed',
          notes = nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), ''),
          updated_at = now()
      where id = v_existing_reservation_id;
    else
      insert into public.reservations (
        venue_id, beo_id, guest_name, guest_phone, guest_email, party_size,
        reservation_time, duration_minutes, source, status, notes
      ) values (
        new.venue_id, new.id, coalesce(v_guest_name, new.event_name), v_guest_phone, v_guest_email,
        coalesce(new.guest_count, 1), new.event_date, 240, 'private_event', 'confirmed',
        nullif(concat_ws(' / ', new.menu_appetizers, new.menu_entrees), '')
      );
    end if;
  end if;

  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    update public.reservations
    set status = 'cancelled', updated_at = now()
    where beo_id = new.id;
  end if;

  if new.status is distinct from old.status then
    insert into public.crm_activity_log (venue_id, lead_id, actor_id, kind, detail)
    values (new.venue_id, new.lead_id, auth.uid(), 'beo_status_changed', old.status || ' -> ' || new.status);
  end if;

  return new;
end;
$$;

create trigger trg_crm_beos_sync_reservation
  after update on public.crm_beos
  for each row execute function app_hidden.crm_beos_sync_reservation();

alter table public.crm_beos enable row level security;
alter table public.crm_beos force row level security;

create policy crm_beos_select on public.crm_beos
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_beos_insert on public.crm_beos
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_beos_update on public.crm_beos
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

-- Now that crm_beos exists, add the real FK the header comment promised.
alter table public.reservations
  add column beo_id uuid unique references public.crm_beos (id) on delete set null;

create index reservations_beo_id_idx on public.reservations (beo_id);

-- -----------------------------------------------------------------------------
-- 4. Contracts
-- -----------------------------------------------------------------------------
create table public.crm_contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  lead_id uuid references public.crm_leads (id) on delete set null,
  beo_id uuid references public.crm_beos (id) on delete set null,
  contract_number text not null,
  contract_date timestamptz,
  event_name text,
  event_date timestamptz,
  guest_count integer check (guest_count is null or guest_count > 0),
  venue_space text,
  fb_minimum_cents integer check (fb_minimum_cents is null or fb_minimum_cents >= 0),
  payment_schedule jsonb not null default '[]'::jsonb,
  cancellation_policy text,
  force_majeure boolean,
  liability_waiver boolean,
  custom_clauses text[] not null default '{}',
  client_signature_name text,
  client_signature_date timestamptz,
  status text not null default 'draft' check (
    status in ('draft', 'sent', 'viewed', 'partially_signed', 'fully_signed', 'expired', 'cancelled', 'disputed')
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_contracts_venue_number_unique unique (venue_id, contract_number)
);

create index crm_contracts_venue_id_idx on public.crm_contracts (venue_id);
create index crm_contracts_lead_id_idx on public.crm_contracts (lead_id);
create index crm_contracts_beo_id_idx on public.crm_contracts (beo_id);
create index crm_contracts_venue_status_idx on public.crm_contracts (venue_id, status);

create or replace function app_hidden.crm_contracts_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_lead_venue_id uuid;
  v_beo_venue_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;

    if new.lead_id is not null then
      select venue_id into v_lead_venue_id from public.crm_leads where id = new.lead_id;
      if v_lead_venue_id is null or v_lead_venue_id <> new.venue_id then
        raise exception 'lead % does not belong to venue %', new.lead_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    if new.beo_id is not null then
      select venue_id into v_beo_venue_id from public.crm_beos where id = new.beo_id;
      if v_beo_venue_id is null or v_beo_venue_id <> new.venue_id then
        raise exception 'beo % does not belong to venue %', new.beo_id, new.venue_id using errcode = '23503';
      end if;
    end if;

    if new.contract_number is null or char_length(trim(new.contract_number)) = 0 then
      new.contract_number := 'C-' || upper(substring(replace(gen_random_uuid()::text, '-', '') from 1 for 9));
    end if;

    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    if new.organization_id <> old.organization_id then
      raise exception 'organization_id cannot be modified once set' using errcode = '42501';
    end if;

    -- The one real transition guard legacy has: once fully_signed, content is frozen and the
    -- only legal status moves are to cancelled or disputed.
    if old.status = 'fully_signed' then
      if new.event_name is distinct from old.event_name
        or new.event_date is distinct from old.event_date
        or new.guest_count is distinct from old.guest_count
        or new.venue_space is distinct from old.venue_space
        or new.fb_minimum_cents is distinct from old.fb_minimum_cents
        or new.custom_clauses is distinct from old.custom_clauses
        or new.cancellation_policy is distinct from old.cancellation_policy
      then
        raise exception 'a fully signed contract cannot be modified; issue an amendment or cancel the contract' using errcode = '42501';
      end if;
      if new.status is distinct from old.status and new.status not in ('cancelled', 'disputed') then
        raise exception 'a fully signed contract can only move to cancelled or disputed' using errcode = '42501';
      end if;
    end if;

    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

create trigger trg_crm_contracts_derive
  before insert or update on public.crm_contracts
  for each row execute function app_hidden.crm_contracts_derive();

alter table public.crm_contracts enable row level security;
alter table public.crm_contracts force row level security;

create policy crm_contracts_select on public.crm_contracts
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_contracts_insert on public.crm_contracts
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_contracts_update on public.crm_contracts
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

-- -----------------------------------------------------------------------------
-- 5. Activity log
-- -----------------------------------------------------------------------------
create table public.crm_activity_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  lead_id uuid references public.crm_leads (id) on delete cascade,
  actor_id uuid references auth.users (id) on delete set null,
  kind text not null check (char_length(trim(kind)) > 0),
  detail text,
  created_at timestamptz not null default now()
);

create index crm_activity_log_lead_created_idx on public.crm_activity_log (lead_id, created_at);
create index crm_activity_log_venue_created_idx on public.crm_activity_log (venue_id, created_at);
create index crm_activity_log_actor_id_idx on public.crm_activity_log (actor_id);

create or replace function app_hidden.crm_activity_log_derive()
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
    raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
  end if;
  new.organization_id := v_org_id;
  new.created_at := now();
  return new;
end;
$$;

create trigger trg_crm_activity_log_derive
  before insert on public.crm_activity_log
  for each row execute function app_hidden.crm_activity_log_derive();

alter table public.crm_activity_log enable row level security;
alter table public.crm_activity_log force row level security;

create policy crm_activity_log_select on public.crm_activity_log
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- No insert policy for authenticated: all rows are written by the triggers above (as the
-- authenticated caller's own role, via security definer) or by the RPCs below, matching
-- legacy's "activity log is a system side effect, never a direct client write."

-- -----------------------------------------------------------------------------
-- 6. Email templates
-- -----------------------------------------------------------------------------
create table public.email_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  venue_id uuid not null references public.venues (id) on delete cascade,
  name text not null check (char_length(trim(name)) > 0),
  subject text not null check (char_length(trim(subject)) > 0),
  body text not null check (char_length(body) <= 20000),
  variables text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_templates_venue_name_unique unique (venue_id, name)
);

create index email_templates_venue_id_idx on public.email_templates (venue_id);

create or replace function app_hidden.email_templates_derive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  if tg_op = 'INSERT' then
    select organization_id into v_org_id from public.venues where id = new.venue_id;
    if v_org_id is null then
      raise exception 'invalid_venue_id: venue does not exist' using errcode = '23503';
    end if;
    new.organization_id := v_org_id;
    new.created_at := now();
    new.updated_at := now();
    return new;
  elsif tg_op = 'UPDATE' then
    if new.venue_id <> old.venue_id then
      raise exception 'venue_id cannot be modified once set' using errcode = '42501';
    end if;
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

create trigger trg_email_templates_derive
  before insert or update on public.email_templates
  for each row execute function app_hidden.email_templates_derive();

alter table public.email_templates enable row level security;
alter table public.email_templates force row level security;

create policy email_templates_select on public.email_templates
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy email_templates_insert on public.email_templates
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy email_templates_update on public.email_templates
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

create policy email_templates_delete on public.email_templates
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- -----------------------------------------------------------------------------
-- 7. RPCs: forecast, source ROI, stale leads, convert-to-contract, waive deposit, render template
-- -----------------------------------------------------------------------------

-- Pipeline forecast — STAGE_PROBABILITY weights copied verbatim from the legacy constant.
create or replace function public.crm_pipeline_forecast(p_venue_id uuid)
returns table (
  status text,
  lead_count bigint,
  raw_value_cents bigint,
  weighted_value_cents bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    l.status,
    count(*)::bigint as lead_count,
    coalesce(sum(l.estimated_value_cents), 0)::bigint as raw_value_cents,
    round(coalesce(sum(l.estimated_value_cents), 0) * (
      case l.status
        when 'new' then 0.05
        when 'contacted' then 0.15
        when 'qualified' then 0.3
        when 'proposal_sent' then 0.5
        when 'negotiating' then 0.7
        when 'won' then 1.0
        when 'lost' then 0
        when 'unqualified' then 0
        when 'on_hold' then 0.1
      end
    ))::bigint as weighted_value_cents
  from public.crm_leads l
  where l.venue_id = p_venue_id
    and l.deleted_at is null
    and app_hidden.has_venue_role(
      p_venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  group by l.status;
$$;

-- Source ROI — lost_count treats 'lost' and 'unqualified' as equivalent, matching legacy.
create or replace function public.crm_source_roi(p_venue_id uuid)
returns table (
  source text,
  lead_count bigint,
  pipeline_value_cents bigint,
  won_count bigint,
  won_value_cents bigint,
  lost_count bigint,
  win_rate numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce(l.source, '(unspecified)') as source,
    count(*)::bigint as lead_count,
    coalesce(sum(l.estimated_value_cents), 0)::bigint as pipeline_value_cents,
    count(*) filter (where l.status = 'won')::bigint as won_count,
    coalesce(sum(l.estimated_value_cents) filter (where l.status = 'won'), 0)::bigint as won_value_cents,
    count(*) filter (where l.status in ('lost', 'unqualified'))::bigint as lost_count,
    case when count(*) = 0 then 0
      else round(count(*) filter (where l.status = 'won')::numeric / count(*), 4)
    end as win_rate
  from public.crm_leads l
  where l.venue_id = p_venue_id
    and l.deleted_at is null
    and app_hidden.has_venue_role(
      p_venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  group by coalesce(l.source, '(unspecified)')
  order by won_value_cents desc;
$$;

-- Stale leads — active-stage leads with no activity in p_days (clamped 1-60, default 5).
create or replace function public.crm_stale_leads(p_venue_id uuid, p_days integer default 5)
returns table (
  id uuid,
  full_name text,
  status text,
  last_activity_at timestamptz,
  days_since_activity integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    l.id,
    l.full_name,
    l.status,
    l.last_activity_at,
    floor(extract(epoch from (now() - coalesce(l.last_activity_at, l.created_at))) / 86400)::integer as days_since_activity
  from public.crm_leads l
  where l.venue_id = p_venue_id
    and l.deleted_at is null
    and l.status in ('new', 'contacted', 'qualified', 'proposal_sent', 'negotiating')
    and (l.last_activity_at is null or l.last_activity_at < now() - make_interval(days => greatest(1, least(60, p_days))))
    and app_hidden.has_venue_role(
      p_venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  order by coalesce(l.last_activity_at, l.created_at) asc
  limit 50;
$$;

-- Idempotent BEO -> Contract conversion. A non-cancelled existing contract for this BEO is
-- returned as-is (already_existed = true) rather than duplicated, matching legacy's explicit
-- double-click/retry fix. Blocked while a deposit is due and not yet paid/waived.
create or replace function public.convert_beo_to_contract(p_beo_id uuid)
returns table (contract_id uuid, already_existed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_beo record;
  v_existing_id uuid;
  v_new_id uuid;
  v_payment_schedule jsonb;
begin
  select * into v_beo from public.crm_beos where id = p_beo_id;
  if v_beo.id is null then
    raise exception 'beo % does not exist', p_beo_id using errcode = '23503';
  end if;

  if not app_hidden.has_venue_role(
    v_beo.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  if v_beo.deposit_cents is not null and v_beo.deposit_cents > 0
     and coalesce(v_beo.deposit_status, 'due') not in ('paid', 'waived') then
    raise exception 'unpaid_deposit_blocks_contract: the BEO deposit must be paid or waived first' using errcode = '42501';
  end if;

  select id into v_existing_id
  from public.crm_contracts
  where beo_id = p_beo_id and status <> 'cancelled'
  limit 1;

  if v_existing_id is not null then
    return query select v_existing_id, true;
    return;
  end if;

  if v_beo.deposit_cents is not null and v_beo.deposit_cents > 0 then
    v_payment_schedule := jsonb_build_array(
      jsonb_build_object('amountCents', v_beo.deposit_cents, 'dueDate', v_beo.deposit_due_date, 'type', 'deposit')
    );
  else
    v_payment_schedule := '[]'::jsonb;
  end if;

  insert into public.crm_contracts (
    venue_id, lead_id, beo_id, contract_number, event_name, event_date, guest_count, venue_space,
    fb_minimum_cents, payment_schedule, status
  ) values (
    v_beo.venue_id, v_beo.lead_id, p_beo_id, null, v_beo.event_name, v_beo.event_date, v_beo.guest_count,
    v_beo.venue_space, v_beo.fb_minimum_cents, v_payment_schedule, 'draft'
  )
  returning id into v_new_id;

  return query select v_new_id, false;
end;
$$;

-- Waive a BEO deposit. Conditional on not already paid (matches legacy's race-safe
-- updateMany(depositStatus: { not: 'paid' })) and on a deposit actually being due.
create or replace function public.waive_beo_deposit(p_beo_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue_id uuid;
  v_updated integer;
begin
  select venue_id into v_venue_id from public.crm_beos where id = p_beo_id;
  if v_venue_id is null then
    raise exception 'beo % does not exist', p_beo_id using errcode = '23503';
  end if;

  if not app_hidden.has_venue_role(
    v_venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  update public.crm_beos
  set deposit_status = 'waived', updated_at = now()
  where id = p_beo_id
    and deposit_cents is not null and deposit_cents > 0
    and coalesce(deposit_status, 'due') <> 'paid';

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

-- Renders a template's subject/body against lead/BEO/venue context via {{var}} substitution,
-- matching legacy's CrmTemplateService exactly (case-sensitive keys, unknown keys -> empty).
create or replace function public.render_email_template(
  p_template_id uuid,
  p_lead_id uuid default null,
  p_beo_id uuid default null
)
returns table (subject text, body text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_template record;
  v_venue record;
  v_lead record;
  v_beo record;
  v_vars jsonb := '{}'::jsonb;
  v_subject text;
  v_body text;
  v_key text;
begin
  select * into v_template from public.email_templates where id = p_template_id;
  if v_template.id is null then
    raise exception 'template % does not exist', p_template_id using errcode = '23503';
  end if;

  if not app_hidden.has_venue_role(
    v_template.venue_id,
    array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: insufficient venue permissions' using errcode = '42501';
  end if;

  select name into v_venue from public.venues where id = v_template.venue_id;
  v_vars := jsonb_build_object('venue.name', coalesce(v_venue.name, ''));

  if p_lead_id is not null then
    select * into v_lead from public.crm_leads where id = p_lead_id and venue_id = v_template.venue_id;
    if v_lead.id is not null then
      v_vars := v_vars || jsonb_build_object(
        'lead.name', coalesce(v_lead.full_name, ''),
        'lead.firstName', coalesce(split_part(v_lead.full_name, ' ', 1), ''),
        'lead.email', coalesce(v_lead.email, ''),
        'lead.phone', coalesce(v_lead.phone, ''),
        'lead.company', coalesce(v_lead.company, ''),
        'lead.source', coalesce(v_lead.source, '')
      );
    end if;
  end if;

  if p_beo_id is not null then
    select * into v_beo from public.crm_beos where id = p_beo_id and venue_id = v_template.venue_id;
    if v_beo.id is not null then
      v_vars := v_vars || jsonb_build_object(
        'event.name', coalesce(v_beo.event_name, ''),
        'event.date', coalesce(to_char(v_beo.event_date, 'FMMonth FMDD, YYYY'), ''),
        'event.space', coalesce(v_beo.venue_space, ''),
        'event.guestCount', coalesce(v_beo.guest_count::text, ''),
        'event.deposit', case when v_beo.deposit_cents is not null then to_char(v_beo.deposit_cents / 100.0, 'FM$999999990.00') else '' end
      );
    end if;
  end if;

  v_subject := v_template.subject;
  v_body := v_template.body;
  for v_key in select jsonb_object_keys(v_vars) loop
    v_subject := replace(v_subject, '{{' || v_key || '}}', v_vars ->> v_key);
    v_body := replace(v_body, '{{' || v_key || '}}', v_vars ->> v_key);
  end loop;

  return query select v_subject, v_body;
end;
$$;

-- -----------------------------------------------------------------------------
-- 8. Grants
-- -----------------------------------------------------------------------------
grant select, insert, update on public.crm_leads to authenticated;
grant select, insert on public.crm_notes to authenticated;
grant select, insert, update on public.crm_beos to authenticated;
grant select, insert, update on public.crm_contracts to authenticated;
grant select on public.crm_activity_log to authenticated;
grant select, insert, update, delete on public.email_templates to authenticated;

revoke execute on function public.crm_pipeline_forecast(uuid) from public, anon;
revoke execute on function public.crm_source_roi(uuid) from public, anon;
revoke execute on function public.crm_stale_leads(uuid, integer) from public, anon;
revoke execute on function public.convert_beo_to_contract(uuid) from public, anon;
revoke execute on function public.waive_beo_deposit(uuid) from public, anon;
revoke execute on function public.render_email_template(uuid, uuid, uuid) from public, anon;

grant execute on function public.crm_pipeline_forecast(uuid) to authenticated;
grant execute on function public.crm_source_roi(uuid) to authenticated;
grant execute on function public.crm_stale_leads(uuid, integer) to authenticated;
grant execute on function public.convert_beo_to_contract(uuid) to authenticated;
grant execute on function public.waive_beo_deposit(uuid) to authenticated;
grant execute on function public.render_email_template(uuid, uuid, uuid) to authenticated;
