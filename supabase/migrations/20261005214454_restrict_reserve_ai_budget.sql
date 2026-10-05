-- reserve_ai_budget takes the org id, user id and budget from its caller and does no
-- membership check, so any signed-in user could call it for any organization (flooding
-- another org's pending reservations to trip its rate limit). Its only caller is the
-- ai-assistant Edge Function, which uses the service-role client — restrict execution to it.
revoke execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.reserve_ai_budget(uuid, uuid, numeric, numeric, integer, integer, integer)
  to service_role;
