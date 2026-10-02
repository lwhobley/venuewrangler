-- Migration: 20261002280000_chat_schema.sql
-- Module: chat (Phase 4, Batch 2)
-- Description: Adds conversations, conversation_members, messages, conversation_reads,
-- private chat storage bucket, automatic storage_deletion_jobs queueing on message delete,
-- derive triggers, and strict RLS.

-- -----------------------------------------------------------------------------
-- 1. Private Chat Storage Bucket & Policies
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('chat', 'chat', false)
on conflict (id) do nothing;

create policy "chat_select_venue_members" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'chat'
    and app_hidden.has_venue_role(
      app_hidden.storage_path_venue_id(name),
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy "chat_insert_venue_members" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'chat'
    and app_hidden.has_venue_role(
      app_hidden.storage_path_venue_id(name),
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- -----------------------------------------------------------------------------
-- 2. Conversations
-- -----------------------------------------------------------------------------
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  type text not null default 'dm' check (type in ('dm', 'group', 'all_staff')),
  name text,
  is_system boolean not null default false,
  last_message_at timestamptz,
  last_message_text text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists conversations_venue_id_idx on public.conversations (venue_id);
create index if not exists conversations_venue_last_msg_idx on public.conversations (venue_id, last_message_at desc nulls last);

create or replace function app_hidden.conversations_derive_org()
returns trigger
language plpgsql
security definer
set search_path = ''
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

drop trigger if exists trg_conversations_derive_org on public.conversations;
create trigger trg_conversations_derive_org
  before insert or update on public.conversations
  for each row
  execute function app_hidden.conversations_derive_org();

alter table public.conversations enable row level security;
alter table public.conversations force row level security;

-- -----------------------------------------------------------------------------
-- 3. Conversation Members
-- -----------------------------------------------------------------------------
create table if not exists public.conversation_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint conversation_members_unique unique (conversation_id, user_id)
);

create index if not exists conversation_members_user_idx on public.conversation_members (user_id);
create index if not exists conversation_members_conv_idx on public.conversation_members (conversation_id);

create or replace function app_hidden.conversation_members_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conv_venue_id uuid;
  v_conv_org_id uuid;
begin
  select venue_id, organization_id into v_conv_venue_id, v_conv_org_id
  from public.conversations where id = new.conversation_id;

  if v_conv_venue_id is null then
    raise exception 'invalid_conversation_id: conversation does not exist' using errcode = '23503';
  end if;

  new.venue_id := v_conv_venue_id;
  new.organization_id := v_conv_org_id;
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists trg_conversation_members_derive on public.conversation_members;
create trigger trg_conversation_members_derive
  before insert on public.conversation_members
  for each row
  execute function app_hidden.conversation_members_derive();

alter table public.conversation_members enable row level security;
alter table public.conversation_members force row level security;

-- Membership check helper avoiding recursive RLS
create or replace function app_hidden.is_conversation_member(
  p_conv_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.conversation_members
    where conversation_id = p_conv_id
      and user_id = coalesce(p_user_id, auth.uid())
  );
$$;

-- -----------------------------------------------------------------------------
-- 4. Messages
-- -----------------------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  text text,
  attachment_path text,
  reactions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint messages_content_check check (
    (text is not null and char_length(trim(text)) > 0)
    or (attachment_path is not null and char_length(trim(attachment_path)) > 0)
  )
);

create index if not exists messages_conv_created_idx on public.messages (conversation_id, created_at asc);
create index if not exists messages_venue_id_idx on public.messages (venue_id);

create or replace function app_hidden.messages_derive_and_touch()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conv_venue_id uuid;
  v_conv_org_id uuid;
begin
  if tg_op = 'INSERT' then
    select venue_id, organization_id into v_conv_venue_id, v_conv_org_id
    from public.conversations where id = new.conversation_id;

    if v_conv_venue_id is null then
      raise exception 'invalid_conversation_id: conversation does not exist' using errcode = '23503';
    end if;

    new.venue_id := v_conv_venue_id;
    new.organization_id := v_conv_org_id;
    new.created_at := now();
    new.updated_at := now();

    -- Update conversation last_message tracking
    update public.conversations
    set
      last_message_at = now(),
      last_message_text = coalesce(new.text, '[Attachment]'),
      updated_at = now()
    where id = new.conversation_id;

    return new;
  elsif tg_op = 'UPDATE' then
    new.updated_at := now();
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_messages_derive_and_touch on public.messages;
create trigger trg_messages_derive_and_touch
  before insert or update on public.messages
  for each row
  execute function app_hidden.messages_derive_and_touch();

-- Durable media cleanup queue trigger: when a message with an attachment is deleted,
-- enqueue an object deletion job in public.storage_deletion_jobs
create or replace function app_hidden.enqueue_chat_attachment_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.attachment_path is not null and char_length(trim(old.attachment_path)) > 0 then
    insert into public.storage_deletion_jobs (
      organization_id,
      venue_id,
      bucket_id,
      object_path
    ) values (
      old.organization_id,
      old.venue_id,
      'chat',
      old.attachment_path
    );
  end if;
  return old;
end;
$$;

drop trigger if exists trg_messages_delete_enqueue_cleanup on public.messages;
create trigger trg_messages_delete_enqueue_cleanup
  after delete on public.messages
  for each row
  execute function app_hidden.enqueue_chat_attachment_deletion();

alter table public.messages enable row level security;
alter table public.messages force row level security;

-- -----------------------------------------------------------------------------
-- 5. Conversation Reads (Read Receipts)
-- -----------------------------------------------------------------------------
create table if not exists public.conversation_reads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  constraint conversation_reads_unique unique (conversation_id, user_id)
);

create index if not exists conversation_reads_conv_user_idx on public.conversation_reads (conversation_id, user_id);

create or replace function app_hidden.conversation_reads_derive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conv_venue_id uuid;
  v_conv_org_id uuid;
begin
  select venue_id, organization_id into v_conv_venue_id, v_conv_org_id
  from public.conversations where id = new.conversation_id;

  if v_conv_venue_id is null then
    raise exception 'invalid_conversation_id: conversation does not exist' using errcode = '23503';
  end if;

  new.venue_id := v_conv_venue_id;
  new.organization_id := v_conv_org_id;
  new.read_at := now();
  return new;
end;
$$;

drop trigger if exists trg_conversation_reads_derive on public.conversation_reads;
create trigger trg_conversation_reads_derive
  before insert on public.conversation_reads
  for each row
  execute function app_hidden.conversation_reads_derive();

alter table public.conversation_reads enable row level security;
alter table public.conversation_reads force row level security;

-- -----------------------------------------------------------------------------
-- 6. RPC Helpers
-- -----------------------------------------------------------------------------

-- Create or get an existing DM conversation between caller and target
create or replace function public.create_or_get_dm(
  p_venue_id uuid,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_id uuid := auth.uid();
  v_conv_id uuid;
  v_org_id uuid;
begin
  if v_caller_id is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if not app_hidden.has_venue_role(
    p_venue_id,
    array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
  ) then
    raise exception 'forbidden: caller is not a member of this venue' using errcode = '42501';
  end if;

  -- Look for existing 2-person DM conversation containing both users
  select c.id into v_conv_id
  from public.conversations c
  join public.conversation_members m1 on m1.conversation_id = c.id and m1.user_id = v_caller_id
  join public.conversation_members m2 on m2.conversation_id = c.id and m2.user_id = p_target_user_id
  where c.venue_id = p_venue_id
    and c.type = 'dm'
  limit 1;

  if v_conv_id is not null then
    return v_conv_id;
  end if;

  select organization_id into v_org_id from public.venues where id = p_venue_id;

  -- Create new DM conversation
  insert into public.conversations (venue_id, organization_id, type)
  values (p_venue_id, v_org_id, 'dm')
  returning id into v_conv_id;

  -- Add both members
  insert into public.conversation_members (conversation_id, user_id, venue_id, organization_id)
  values
    (v_conv_id, v_caller_id, p_venue_id, v_org_id),
    (v_conv_id, p_target_user_id, p_venue_id, v_org_id);

  return v_conv_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Row Level Security Policies
-- -----------------------------------------------------------------------------

-- CONVERSATIONS RLS
create policy conversations_select on public.conversations
  for select to authenticated
  using (
    app_hidden.is_conversation_member(id)
    or (
      type = 'all_staff'
      and app_hidden.has_venue_role(
        venue_id,
        array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
      )
    )
  );

create policy conversations_insert on public.conversations
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

create policy conversations_update on public.conversations
  for update to authenticated
  using (
    app_hidden.is_conversation_member(id)
    or (
      type = 'all_staff'
      and app_hidden.has_venue_role(
        venue_id,
        array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
      )
    )
  );

-- CONVERSATION MEMBERS RLS
create policy conversation_members_select on public.conversation_members
  for select to authenticated
  using (
    app_hidden.is_conversation_member(conversation_id)
    or user_id = auth.uid()
  );

create policy conversation_members_insert on public.conversation_members
  for insert to authenticated
  with check (
    app_hidden.has_venue_role(
      venue_id,
      array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- MESSAGES RLS
create policy messages_select on public.messages
  for select to authenticated
  using (
    app_hidden.is_conversation_member(conversation_id)
    or exists(
      select 1 from public.conversations c
      where c.id = conversation_id
        and c.type = 'all_staff'
        and app_hidden.has_venue_role(
          c.venue_id,
          array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
        )
    )
  );

create policy messages_insert on public.messages
  for insert to authenticated
  with check (
    sender_id = auth.uid()
    and (
      app_hidden.is_conversation_member(conversation_id)
      or exists(
        select 1 from public.conversations c
        where c.id = conversation_id
          and c.type = 'all_staff'
          and app_hidden.has_venue_role(
            c.venue_id,
            array['staff', 'supervisor', 'venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
          )
      )
    )
  );

create policy messages_delete on public.messages
  for delete to authenticated
  using (
    sender_id = auth.uid()
    or app_hidden.has_venue_role(
      venue_id,
      array['venue_manager', 'organization_owner', 'organization_admin']::public.app_role[]
    )
  );

-- CONVERSATION READS RLS
create policy conversation_reads_select on public.conversation_reads
  for select to authenticated
  using (user_id = auth.uid());

create policy conversation_reads_write on public.conversation_reads
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 8. Grants
-- -----------------------------------------------------------------------------
grant select, insert, update on public.conversations to authenticated;
grant select, insert on public.conversation_members to authenticated;
grant select, insert, delete on public.messages to authenticated;
grant select, insert, update on public.conversation_reads to authenticated;
grant execute on function public.create_or_get_dm to authenticated;
