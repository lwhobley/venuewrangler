-- Fixes from the review of the recent changes:
--  * apply_stripe_subscription_state: an ended subscription's late event no longer overwrites a
--    customer's newer live subscription.
--  * inventory_legacy_quantity: the legacy quantity column can no longer drive stock negative.
--  * venue_roster: also lists the organization owners/admins who manage the venue.

create or replace function public.apply_stripe_subscription_state(
  p_organization_id uuid,
  p_customer_id text,
  p_subscription_id text,
  p_price_id text,
  p_status text,
  p_current_period_end timestamptz,
  p_cancel_at_period_end boolean,
  p_event_id text,
  p_event_created bigint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows integer;
begin
  if p_organization_id is not null then
    insert into public.subscriptions as s (
      organization_id, stripe_customer_id, stripe_subscription_id, stripe_price_id, status,
      current_period_end, cancel_at_period_end, last_event_id, last_event_created
    )
    values (
      p_organization_id, p_customer_id, p_subscription_id, p_price_id, p_status,
      p_current_period_end, coalesce(p_cancel_at_period_end, false), p_event_id, p_event_created
    )
    on conflict (organization_id) do update set
      stripe_customer_id = excluded.stripe_customer_id,
      stripe_subscription_id = excluded.stripe_subscription_id,
      stripe_price_id = excluded.stripe_price_id,
      status = excluded.status,
      current_period_end = excluded.current_period_end,
      cancel_at_period_end = excluded.cancel_at_period_end,
      last_event_id = excluded.last_event_id,
      last_event_created = excluded.last_event_created,
      updated_at = now()
    where s.last_event_created is null or s.last_event_created <= excluded.last_event_created;
  else
    update public.subscriptions s set
      stripe_subscription_id = p_subscription_id,
      stripe_price_id = p_price_id,
      status = p_status,
      current_period_end = p_current_period_end,
      cancel_at_period_end = coalesce(p_cancel_at_period_end, false),
      last_event_id = p_event_id,
      last_event_created = p_event_created,
      updated_at = now()
    where s.stripe_customer_id = p_customer_id
      and (s.last_event_created is null or s.last_event_created <= p_event_created)
      -- A customer can hold a newer subscription than the one this event is about. A live
      -- subscription takes over the row; an ended one (e.g. the old plan being canceled) may only
      -- update the row while it still tracks that same subscription.
      and (
        s.stripe_subscription_id is null
        or s.stripe_subscription_id = p_subscription_id
        or p_status not in ('canceled', 'incomplete_expired')
      );
  end if;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;


create or replace function app_hidden.inventory_legacy_quantity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a uuid; s uuid; prev numeric; others numeric;
begin
  if pg_trigger_depth()>1 then return new; end if;
  select id into a from public.inventory_areas where venue_id=new.venue_id and is_default;
  if tg_op='INSERT' then
    insert into public.inventory_stock(organization_id,venue_id,inventory_item_id,area_id,quantity)
    values(new.organization_id,new.venue_id,new.id,a,coalesce(new.quantity,0)) returning id into s;
    if new.quantity is not null then perform app_hidden.inventory_write_history(s,'ADJUSTMENT',0,new.quantity,'Opening balance',null,null,'opening'); end if;
  elsif new.quantity is distinct from old.quantity then
    perform app_hidden.inventory_assert_manager(new.venue_id);
    perform pg_advisory_xact_lock(hashtextextended(new.venue_id::text,0));
    select id,quantity into s,prev from public.inventory_stock where inventory_item_id=new.id and area_id=a and sub_area_id is null for update;
    select coalesce(sum(quantity),0) into others from public.inventory_stock where inventory_item_id=new.id and id<>s;
    -- The RPCs never allow negative stock; neither may this compatibility path. The total can
    -- only be lowered as far as what the other locations already hold.
    if new.quantity-others<0 then
      raise exception 'Quantity cannot be lower than the stock held in other locations (%)',others using errcode='22023';
    end if;
    update public.inventory_stock set quantity=new.quantity-others where id=s;
    perform app_hidden.inventory_write_history(s,'ADJUSTMENT',prev,new.quantity-others,'Legacy quantity correction',null,null,'legacy');
  end if;
  return new;
end $$;

create or replace function public.venue_roster(p_venue_id uuid)
returns table (user_id uuid, role public.app_role, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
     or not app_hidden.has_venue_role(
       p_venue_id,
       array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
     ) then
    raise exception 'Not allowed to view this venue roster' using errcode = '42501';
  end if;

  -- Venue-level members, plus the organization's owners/admins, who manage every venue in it
  -- through an org-level membership (venue_id null). One row per person, venue role first.
  return query
    select r.user_id, r.role, r.display_name
    from (
      select distinct on (m.user_id) m.user_id, m.role, p.display_name
      from public.memberships m
      join public.venues v on v.id = p_venue_id
      left join public.profiles p on p.id = m.user_id
      where m.venue_id = p_venue_id
         or (m.venue_id is null and m.organization_id = v.organization_id
             and m.role in ('organization_owner', 'organization_admin'))
      order by m.user_id, (m.venue_id is null)
    ) r
    order by r.display_name nulls last, r.user_id;
end;
$$;

