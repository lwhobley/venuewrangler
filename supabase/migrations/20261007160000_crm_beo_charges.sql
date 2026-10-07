-- Itemized BEO charges are venue scoped and manager only. A minimum is a
-- commitment, not a charge, and remains on crm_beos.fb_minimum_cents.
alter table public.crm_beos
  add constraint crm_beos_id_venue_unique unique (id, venue_id);

create table public.crm_beo_charges (
  id uuid primary key default gen_random_uuid(),
  beo_id uuid not null,
  venue_id uuid not null,
  description text not null check (
    char_length(trim(description)) between 1 and 160
  ),
  category text not null check (
    category in ('food', 'beverage', 'room', 'service', 'tax', 'discount', 'other')
  ),
  amount_cents integer not null check (amount_cents > 0),
  created_at timestamptz not null default now(),
  constraint crm_beo_charges_beo_venue_fk
    foreign key (beo_id, venue_id)
    references public.crm_beos (id, venue_id) on delete cascade
);

create index crm_beo_charges_beo_created_idx
  on public.crm_beo_charges (beo_id, created_at, id);

alter table public.crm_beo_charges enable row level security;
alter table public.crm_beo_charges force row level security;

create policy crm_beo_charges_select on public.crm_beo_charges
  for select to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_beo_charges_insert on public.crm_beo_charges
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy crm_beo_charges_delete on public.crm_beo_charges
  for delete to authenticated
  using (
    app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

grant select, insert, delete on public.crm_beo_charges to authenticated;
