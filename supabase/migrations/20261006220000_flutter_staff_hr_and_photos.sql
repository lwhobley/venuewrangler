-- Flutter/Supabase staff profiles. Identity photos are team-visible; HR details are not.
create or replace function app_hidden.can_manage_staff_profile(p_venue uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m join public.venues v on v.id = p_venue
    where m.user_id = p_user and m.organization_id = v.organization_id
      and (m.venue_id = p_venue or m.venue_id is null)
  ) and (
    app_hidden.has_venue_role(p_venue, array['organization_owner','organization_admin']::public.app_role[])
    or (
      app_hidden.has_venue_role(p_venue, array['venue_manager']::public.app_role[])
      and not exists (
        select 1 from public.memberships m join public.venues v on v.id = p_venue
        where m.user_id = p_user and m.organization_id = v.organization_id
          and (m.venue_id = p_venue or m.venue_id is null)
          and m.role in ('venue_manager','organization_owner','organization_admin')
      )
    )
  );
$$;

create table public.employee_hr_profiles (
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  legal_name text check (char_length(legal_name) <= 120),
  preferred_name text check (char_length(preferred_name) <= 120),
  contact_email text check (char_length(contact_email) <= 255),
  phone text check (char_length(phone) <= 50),
  alternate_phone text check (char_length(alternate_phone) <= 50),
  address text check (char_length(address) <= 500),
  date_of_birth date check (date_of_birth <= current_date),
  emergency_contact_name text check (char_length(emergency_contact_name) <= 120),
  emergency_contact_relationship text check (char_length(emergency_contact_relationship) <= 80),
  emergency_contact_phone text check (char_length(emergency_contact_phone) <= 50),
  employee_number text check (char_length(employee_number) <= 64),
  job_title text check (char_length(job_title) <= 100),
  department text check (char_length(department) <= 100),
  hire_date date,
  employment_type text check (employment_type in ('full_time','part_time','seasonal','contractor','temporary')),
  employment_status text check (employment_status in ('active','on_leave','inactive')),
  hourly_rate_cents integer check (hourly_rate_cents between 0 and 1000000),
  certifications text[] not null default '{}' check (cardinality(certifications) <= 50),
  pto_hours numeric not null default 0 check (pto_hours between 0 and 10000),
  sick_hours numeric not null default 0 check (sick_hours between 0 and 10000),
  updated_at timestamptz not null default now(),
  primary key (venue_id, user_id)
);

create or replace function app_hidden.guard_employee_hr_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  employment_fields text[] := array['employee_number','job_title','department','hire_date',
    'employment_type','employment_status','hourly_rate_cents','certifications','pto_hours','sick_hours'];
  k text;
  defaults jsonb := '{"certifications": [], "pto_hours": 0, "sick_hours": 0}'::jsonb;
begin
  if tg_op = 'UPDATE' and (new.user_id is distinct from old.user_id or new.venue_id is distinct from old.venue_id) then
    raise exception 'Profile ownership is immutable' using errcode = '42501';
  end if;
  if not app_hidden.can_manage_staff_profile(new.venue_id, new.user_id) then
    foreach k in array employment_fields loop
      if tg_op = 'INSERT' then
        if (to_jsonb(new)->k) is distinct from coalesce(defaults->k, 'null'::jsonb) then
          raise exception 'Only an authorized manager can set employment details' using errcode = '42501';
        end if;
      elsif (to_jsonb(new)->k) is distinct from (to_jsonb(old)->k) then
        raise exception 'Only an authorized manager can change employment details' using errcode = '42501';
      end if;
    end loop;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger guard_employee_hr_profile before insert or update on public.employee_hr_profiles
  for each row execute function app_hidden.guard_employee_hr_profile();

alter table public.employee_hr_profiles enable row level security;
alter table public.employee_hr_profiles force row level security;
create policy employee_hr_read on public.employee_hr_profiles for select to authenticated using (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
  or app_hidden.can_manage_staff_profile(venue_id, user_id)
);
create policy employee_hr_insert on public.employee_hr_profiles for insert to authenticated with check (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
  or app_hidden.can_manage_staff_profile(venue_id, user_id)
);
create policy employee_hr_update on public.employee_hr_profiles for update to authenticated using (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
  or app_hidden.can_manage_staff_profile(venue_id, user_id)
) with check (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id))
  or app_hidden.can_manage_staff_profile(venue_id, user_id)
);
grant select, insert, update on public.employee_hr_profiles to authenticated;

create table public.staff_photos (
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  storage_path text not null,
  updated_at timestamptz not null default now(),
  primary key (venue_id, user_id)
);

-- One stable object per user/venue. Replacing a photo overwrites bytes rather than accumulating
-- orphaned old uploads. The canonical path cannot point at another person's image.
create or replace function app_hidden.guard_staff_photo()
returns trigger language plpgsql security definer set search_path = '' as $$
declare org uuid;
begin
  select organization_id into org from public.venues where id = new.venue_id;
  if new.storage_path is distinct from org::text || '/' || new.venue_id::text || '/' || new.user_id::text || '.photo' then
    raise exception 'Invalid profile photo path' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (new.user_id is distinct from old.user_id or new.venue_id is distinct from old.venue_id) then
    raise exception 'Photo ownership is immutable' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger guard_staff_photo before insert or update on public.staff_photos
  for each row execute function app_hidden.guard_staff_photo();
alter table public.staff_photos enable row level security;
alter table public.staff_photos force row level security;
create policy staff_photos_read on public.staff_photos for select to authenticated
  using (app_hidden.is_venue_member(venue_id));
create policy staff_photos_insert on public.staff_photos for insert to authenticated with check (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id)) or app_hidden.can_manage_staff_profile(venue_id,user_id)
);
create policy staff_photos_update on public.staff_photos for update to authenticated using (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id)) or app_hidden.can_manage_staff_profile(venue_id,user_id)
) with check (
  (user_id = auth.uid() and app_hidden.is_venue_member(venue_id)) or app_hidden.can_manage_staff_profile(venue_id,user_id)
);
grant select, insert, update on public.staff_photos to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('profile-photos','profile-photos',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function app_hidden.profile_photo_access(p_path text, p_write boolean)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare parts text[]; v uuid; u uuid; org uuid;
begin
  if p_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.photo$' then return false; end if;
  parts := string_to_array(p_path,'/');
  org := app_hidden.try_cast_uuid(parts[1]);
  v := app_hidden.try_cast_uuid(parts[2]);
  u := app_hidden.try_cast_uuid(split_part(parts[3],'.',1));
  if org is null or v is null or u is null or not exists (select 1 from public.venues where id=v and organization_id=org) then return false; end if;
  if p_write then
    return (u=auth.uid() and app_hidden.is_venue_member(v)) or app_hidden.can_manage_staff_profile(v,u);
  end if;
  return app_hidden.is_venue_member(v);
end;
$$;
create policy profile_photos_storage_read on storage.objects for select to authenticated
  using (bucket_id='profile-photos' and app_hidden.profile_photo_access(name,false));
create policy profile_photos_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id='profile-photos' and app_hidden.profile_photo_access(name,true));
create policy profile_photos_storage_update on storage.objects for update to authenticated
  using (bucket_id='profile-photos' and app_hidden.profile_photo_access(name,true))
  with check (bucket_id='profile-photos' and app_hidden.profile_photo_access(name,true));
revoke all on function app_hidden.can_manage_staff_profile(uuid,uuid), app_hidden.profile_photo_access(text,boolean) from public, anon;
grant execute on function app_hidden.can_manage_staff_profile(uuid,uuid), app_hidden.profile_photo_access(text,boolean) to authenticated;
