import { describe, expect, it } from 'vitest';
// @ts-expect-error -- shared CLI guard is an ES module used by Node directly.
import { assertSameDatabaseTarget } from './database-target.mjs';

describe('Migration database identity', () => {
  const pooler = 'postgresql://venue_api.projectabc:fixture@aws-0-us-east-1.pooler.supabase.com:5432/postgres?sslmode=require';
  const direct = 'postgresql://postgres:fixture@db.projectabc.supabase.co:5432/postgres?schema=public';

  it('accepts separate roles and hosts for the same Supabase project', () => {
    expect(() => assertSameDatabaseTarget(pooler, direct)).not.toThrow();
  });

  it('rejects a different Supabase project without exposing either credential', () => {
    expect(() => assertSameDatabaseTarget(pooler, direct.replace('projectabc', 'projectother'))).toThrow('target different projects');
  });

  it('rejects a different schema or database in the same project', () => {
    expect(() => assertSameDatabaseTarget(pooler, direct.replace('schema=public', 'schema=staging'))).toThrow('target different projects');
    expect(() => assertSameDatabaseTarget(pooler, direct.replace('/postgres?', '/staging?'))).toThrow('target different projects');
  });

  it('distinguishes local instances by port while accepting loopback aliases', () => {
    expect(() => assertSameDatabaseTarget('postgresql://postgres@localhost/test', 'postgresql://owner@127.0.0.1:5432/test')).not.toThrow();
    expect(() => assertSameDatabaseTarget('postgresql://postgres@localhost/test', 'postgresql://postgres@localhost:55432/test')).toThrow('target different projects');
  });

  it('rejects an ambiguous pooler username', () => {
    expect(() => assertSameDatabaseTarget(pooler.replace('venue_api.projectabc', 'postgres'), direct)).toThrow('must identify their project');
  });
});
