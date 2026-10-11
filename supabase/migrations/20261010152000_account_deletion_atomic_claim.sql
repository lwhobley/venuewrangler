create or replace function public.claim_account_deletion_job(p_job_id uuid)
returns table (id uuid, user_id uuid, attempts integer)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  update public.account_deletion_jobs j
  set status = 'processing', attempts = j.attempts + 1, updated_at = now()
  where j.id = p_job_id
    and j.attempts < 10
    and (
      j.status in ('pending', 'failed')
      or (j.status = 'processing' and j.updated_at < now() - interval '15 minutes')
    )
  returning j.id, j.user_id, j.attempts;
end;
$$;

revoke all on function public.claim_account_deletion_job(uuid) from public, anon, authenticated;
grant execute on function public.claim_account_deletion_job(uuid) to service_role;
