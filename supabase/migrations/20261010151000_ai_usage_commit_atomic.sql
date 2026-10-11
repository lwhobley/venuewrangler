alter table public.ai_usage_events
  add column if not exists reservation_id uuid unique
    references public.ai_budget_reservations(id) on delete set null;

create or replace function public.commit_ai_reservation(
  p_reservation_id uuid,
  p_organization_id uuid,
  p_venue_id uuid,
  p_user_id uuid,
  p_task text,
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cost_usd numeric
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reservation public.ai_budget_reservations;
begin
  perform pg_advisory_xact_lock(hashtext('ai_budget:' || p_organization_id::text));
  select * into v_reservation
  from public.ai_budget_reservations
  where id = p_reservation_id
  for update;

  if not found or v_reservation.organization_id <> p_organization_id then
    raise exception 'AI reservation not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.ai_usage_events where reservation_id = p_reservation_id) then
    return;
  end if;
  if v_reservation.status <> 'pending' then
    raise exception 'AI reservation is no longer pending' using errcode = '22023';
  end if;
  if p_cost_usd < 0 or p_input_tokens < 0 or p_output_tokens < 0 then
    raise exception 'invalid AI usage values' using errcode = '22023';
  end if;

  update public.ai_budget_reservations set status = 'committed'
  where id = p_reservation_id;
  insert into public.ai_usage_events (
    organization_id, venue_id, user_id, task, model,
    input_tokens, output_tokens, cost_usd, reservation_id
  ) values (
    p_organization_id, p_venue_id, p_user_id, p_task, p_model,
    p_input_tokens, p_output_tokens, p_cost_usd, p_reservation_id
  );
end;
$$;

revoke all on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  from public, anon, authenticated;
grant execute on function public.commit_ai_reservation(uuid, uuid, uuid, uuid, text, text, integer, integer, numeric)
  to service_role;
