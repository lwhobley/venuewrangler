-- A device-held random secret authorizes revocation across account changes.
-- Store only its digest; knowledge of a transport token alone grants no rights.
alter table public.push_tokens add column revocation_secret_hash text;

-- Legacy registrations have no proof-of-possession credential. Retire them;
-- upgraded clients register again when a venue is selected.
update public.push_tokens set enabled = false, disabled_at = now(), updated_at = now()
where enabled;

create function public.register_push_token_for_device(
  p_venue_id uuid, p_token text, p_platform text, p_revocation_secret text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_hash text; v_id uuid;
begin
  if auth.uid() is null or not app_hidden.is_venue_member(p_venue_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_revocation_secret is null or p_revocation_secret !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid installation secret' using errcode = '22023';
  end if;
  v_hash := encode(sha256(convert_to(p_revocation_secret, 'UTF8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('push-installation:' || p_token, 0));
  -- Account change on the same installation: revoke its prior account rows at
  -- every venue. A guessed token with a different secret cannot reach this path.
  update public.push_tokens set enabled = false, disabled_at = now(), updated_at = now()
    where token = p_token and revocation_secret_hash = v_hash and user_id <> auth.uid();
  v_id := public.register_push_token(p_venue_id, p_token, p_platform);
  update public.push_tokens set revocation_secret_hash = v_hash where id = v_id;
  return v_id;
end;
$$;

create function public.revoke_device_push_token(p_token text, p_revocation_secret text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_hash text;
begin
  if auth.uid() is null then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_revocation_secret is null or p_revocation_secret !~ '^[0-9a-f]{64}$' then
    return false;
  end if;
  v_hash := encode(sha256(convert_to(p_revocation_secret, 'UTF8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('push-installation:' || p_token, 0));
  if exists (select 1 from public.push_tokens where token = p_token and enabled
             and revocation_secret_hash is distinct from v_hash) then
    return false;
  end if;
  update public.push_tokens set enabled = false, disabled_at = now(), updated_at = now()
    where token = p_token and revocation_secret_hash = v_hash and enabled;
  return true; -- Also true for an already-revoked/deleted installation.
end;
$$;
revoke all on function public.register_push_token_for_device(uuid, text, text, text) from public, anon;
revoke all on function public.revoke_device_push_token(text, text) from public, anon;
grant execute on function public.register_push_token_for_device(uuid, text, text, text) to authenticated;
grant execute on function public.revoke_device_push_token(text, text) to authenticated;
