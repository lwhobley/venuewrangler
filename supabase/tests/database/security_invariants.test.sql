-- Catalog-wide security invariants (audit D-02 / F-15). These fail CI when a future migration
-- adds a table without RLS, a SECURITY DEFINER function without a pinned search_path, or any
-- anon/over-broad client access, instead of relying on someone remembering to check.

begin;
select plan(11);

select is_empty(
  $$ select c.oid::regclass from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p')
       and not (c.relrowsecurity and c.relforcerowsecurity) $$,
  'every public table has row level security enabled AND forced'
);

select is_empty(
  $$ select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app_hidden') and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%') $$,
  'every SECURITY DEFINER function pins its search_path'
);

select is_empty(
  $$ select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind in ('f', 'p')
       and has_function_privilege('anon', p.oid, 'execute')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') $$,
  'anon cannot execute any function in public'
);

select is_empty(
  $$ select c.oid::regclass from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
       and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
            or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete')) $$,
  'anon has no table privileges in public'
);

select is_empty(
  $$ select tablename, policyname from pg_policies
     where schemaname = 'public' and not (roles = array['authenticated']::name[]) $$,
  'every public policy is scoped to authenticated only (never anon or PUBLIC)'
);

select is_empty(
  $$ select c.oid::regclass, t.cmd
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) t(cmd)
     where n.nspname = 'public' and c.relkind in ('r', 'p')
       and has_table_privilege('authenticated', c.oid, t.cmd)
       and not exists (
         select 1 from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname
           and p.cmd in (t.cmd, 'ALL') and p.roles && array['authenticated', 'public']::name[]
       ) $$,
  'authenticated holds table-level privileges only for commands that have a policy'
);

select is_empty(
  $$ select c.oid::regclass from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v' $$,
  'no views exist in public (views bypass RLS unless security_invoker is set)'
);

-- Default privileges: a table created by a future migration starts with no client access.
create table public.zz_probe_table (id int);
create function public.zz_probe_fn() returns int language sql as $$ select 1 $$;

select ok(
  not has_table_privilege('anon', 'public.zz_probe_table', 'select')
  and not has_table_privilege('authenticated', 'public.zz_probe_table', 'select'),
  'new tables in public are not readable by anon/authenticated until a migration grants access'
);
select ok(
  not has_function_privilege('anon', 'public.zz_probe_fn()', 'execute')
  and not has_function_privilege('authenticated', 'public.zz_probe_fn()', 'execute'),
  'new functions in public are not executable by anon/authenticated until a migration grants access'
);

-- Secrets and server-only tables are unreachable for every client role.
select ok(
  not has_table_privilege('authenticated', 'public.retained_wage_profiles', 'select')
  and not has_table_privilege('authenticated', 'app_hidden.platform_settings', 'select')
  and not has_table_privilege('authenticated', 'app_hidden.rate_limit_counters', 'select'),
  'legal-hold, settings and rate-limit tables are not client-readable'
);

select ok(
  not has_column_privilege('authenticated', 'public.pos_checks', 'raw_payload', 'select'),
  'raw POS webhook payloads are not readable by clients'
);

select * from finish();
rollback;
