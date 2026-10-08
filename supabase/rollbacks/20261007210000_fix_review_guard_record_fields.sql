-- Restores the versions from 20261007202000_review_tenant_guards.sql (reintroduces the
-- "record has no field" bug this migration fixes -- see that migration's comment).

create or replace function app_hidden.guard_review_row_update()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.venue_id is distinct from old.venue_id then
    raise exception 'row ownership cannot be changed' using errcode = '42501';
  end if;
  if tg_table_name = 'shift_swaps'
     and new.shift_id is distinct from old.shift_id then
    raise exception 'swap shift cannot be changed' using errcode = '42501';
  end if;
  if tg_table_name = 'shift_swaps' and new.status = 'accepted'
     and old.status is distinct from 'accepted' then
    if new.accepted_by is null or not exists (
      select 1 from public.memberships m
      where m.user_id = new.accepted_by
        and m.organization_id = old.organization_id
        and (m.venue_id = old.venue_id or m.venue_id is null)
    ) then
      raise exception 'swap accepter must belong to the shift venue'
        using errcode = '42501';
    end if;
  end if;
  if tg_table_name = 'time_entries'
     and (new.location_anomaly is distinct from old.location_anomaly
          or new.shift_id is distinct from old.shift_id)
     and coalesce(current_setting('app.time_entry_correction', true), '') <> 'on' then
    raise exception 'punch integrity fields require a manager correction' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function app_hidden.guard_crm_links()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.lead_id is not null and not exists (
    select 1 from public.crm_leads where id = new.lead_id and venue_id = new.venue_id
  ) then
    raise exception 'lead belongs to another venue' using errcode = '23503';
  end if;
  if tg_table_name = 'crm_contracts' and new.beo_id is not null and not exists (
    select 1 from public.crm_beos where id = new.beo_id and venue_id = new.venue_id
  ) then
    raise exception 'BEO belongs to another venue' using errcode = '23503';
  end if;
  return new;
end;
$$;
