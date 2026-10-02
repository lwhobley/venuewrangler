-- pgTAP authorization and functionality tests for chat module (20261002280000).
-- Fixtures: Org A, Venue A1 (manager 004, staff 1 005, staff 2 008), Org B, Venue B1 (owner 006).

begin;
select plan(14);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000004', 'venue-a1-manager@example.com'),
  ('00000000-0000-0000-0000-000000000005', 'venue-a1-staff1@example.com'),
  ('00000000-0000-0000-0000-000000000008', 'venue-a1-staff2@example.com'),
  ('00000000-0000-0000-0000-000000000006', 'org-b-owner@example.com');

insert into public.organizations (id, name) values
  ('10000000-0000-0000-0000-00000000000a', 'Org A'),
  ('10000000-0000-0000-0000-00000000000b', 'Org B');

insert into public.venues (id, organization_id, name) values
  ('20000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-00000000000a', 'Venue A1'),
  ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Venue B1');

insert into public.memberships (user_id, organization_id, venue_id, role) values
  ('00000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'venue_manager'),
  ('00000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-0000000000a1', 'staff'),
  ('00000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-00000000000b', null, 'organization_owner');

-- ---------------------------------------------------------------------------
-- 1. Trigger test: conversations derives organization_id
-- ---------------------------------------------------------------------------
insert into public.conversations (
  id, venue_id, organization_id, type, name
) values (
  'b0000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-00000000000b', -- wrong org
  'all_staff',
  'All Staff Announcement'
);

select results_eq(
  $$ select organization_id from public.conversations where id = 'b0000000-0000-0000-0000-000000000001' $$,
  $$ values ('10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'conversations derives organization_id from venue_id on insert'
);

-- ---------------------------------------------------------------------------
-- 2. Trigger test: conversation_members derives venue_id and org from conversation
-- ---------------------------------------------------------------------------
insert into public.conversation_members (
  id, conversation_id, user_id, venue_id, organization_id
) values (
  'c0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000005',
  '20000000-0000-0000-0000-00000000000b',
  '10000000-0000-0000-0000-00000000000b'
);

select results_eq(
  $$ select venue_id, organization_id from public.conversation_members where id = 'c0000000-0000-0000-0000-000000000001' $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1'::uuid, '10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'conversation_members derives venue_id and organization_id from conversation'
);

-- ---------------------------------------------------------------------------
-- 3 & 4. Trigger test: messages derives org/venue & touches conversation last_message
-- ---------------------------------------------------------------------------
insert into public.messages (
  id, conversation_id, sender_id, text, venue_id, organization_id
) values (
  'd0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000005',
  'Hello team!',
  '20000000-0000-0000-0000-00000000000b',
  '10000000-0000-0000-0000-00000000000b'
);

select results_eq(
  $$ select venue_id, organization_id from public.messages where id = 'd0000000-0000-0000-0000-000000000001' $$,
  $$ values ('20000000-0000-0000-0000-0000000000a1'::uuid, '10000000-0000-0000-0000-00000000000a'::uuid) $$,
  'messages derives venue_id and organization_id from conversation'
);

select results_eq(
  $$ select last_message_text from public.conversations where id = 'b0000000-0000-0000-0000-000000000001' $$,
  $$ values ('Hello team!'::text) $$,
  'inserting message updates conversation last_message_text'
);

-- ---------------------------------------------------------------------------
-- 5. Media cleanup queue integration: message delete enqueues storage_deletion_job
-- ---------------------------------------------------------------------------
insert into public.messages (
  id, conversation_id, sender_id, text, attachment_path
) values (
  'd0000000-0000-0000-0000-000000000002',
  'b0000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000005',
  'Photo attached',
  '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/receipt.jpg'
);

delete from public.messages where id = 'd0000000-0000-0000-0000-000000000002';

select results_eq(
  $$ select count(*)::int from public.storage_deletion_jobs
     where bucket_id = 'chat'
       and object_path = '10000000-0000-0000-0000-00000000000a/20000000-0000-0000-0000-0000000000a1/receipt.jpg' $$,
  $$ values (1) $$,
  'deleting message with attachment enqueues row in storage_deletion_jobs'
);

-- ---------------------------------------------------------------------------
-- 6 & 7. RPC create_or_get_dm idempotency
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff 1

select ok(
  public.create_or_get_dm(
    '20000000-0000-0000-0000-0000000000a1',
    '00000000-0000-0000-0000-000000000008' -- staff 2
  ) is not null,
  'create_or_get_dm creates new DM between staff 1 and staff 2'
);

select results_eq(
  $$ select public.create_or_get_dm(
       '20000000-0000-0000-0000-0000000000a1',
       '00000000-0000-0000-0000-000000000008'
     ) $$,
  $$ select id from public.conversations where venue_id = '20000000-0000-0000-0000-0000000000a1' and type = 'dm' limit 1 $$,
  'calling create_or_get_dm again returns same existing DM'
);

-- ---------------------------------------------------------------------------
-- 8, 9 & 10. RLS: Member can read messages; Non-member in venue cannot; Org B cannot
-- ---------------------------------------------------------------------------
select results_ne(
  $$ select count(*)::int from public.messages where conversation_id = 'b0000000-0000-0000-0000-000000000001' $$,
  $$ values (0) $$,
  'member can read messages in conversation'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager (not in the private DM)

select is_empty(
  $$ select m.id from public.messages m
     join public.conversations c on c.id = m.conversation_id
     where c.type = 'dm' $$,
  'non-member cannot read messages in private DM'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000006'; -- Org B

select is_empty(
  $$ select id from public.messages where venue_id = '20000000-0000-0000-0000-0000000000a1' $$,
  'org B user cannot read messages from venue A1 (tenant isolation)'
);

-- ---------------------------------------------------------------------------
-- 11 & 12. RLS: Member can send message; Non-member cannot
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff 1

select lives_ok(
  $$ insert into public.messages (conversation_id, sender_id, text)
     values (
       (select id from public.conversations where type = 'dm' limit 1),
       '00000000-0000-0000-0000-000000000005',
       'Hey staff 2!'
     ) $$,
  'staff 1 can send message in DM conversation'
);

reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000004'; -- manager (non-member)

select throws_ok(
  $$ insert into public.messages (conversation_id, sender_id, text)
     values (
       (select id from public.conversations where type = 'dm' limit 1),
       '00000000-0000-0000-0000-000000000004',
       'Crashing DM'
     ) $$,
  '42501',
  null,
  'non-member cannot send message in DM'
);

-- ---------------------------------------------------------------------------
-- 13 & 14. Conversation Reads: Own read record only
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claim.sub" to '00000000-0000-0000-0000-000000000005'; -- staff 1

select lives_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values ('b0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005')
     on conflict (conversation_id, user_id) do update set read_at = now() $$,
  'user can update own read receipt'
);

select throws_ok(
  $$ insert into public.conversation_reads (conversation_id, user_id)
     values ('b0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000008') $$,
  '42501',
  null,
  'user cannot forge another users read receipt'
);

select * from finish();
rollback;
