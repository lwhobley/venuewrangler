"""Run real SQL against a disposable loopback PostgreSQL database (never production).

Usage: python tool/test_inventory_v2_database.py --port 55439 --psql "path/to/psql"
The caller starts PostgreSQL. This script creates and removes only its randomly named DB.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=55439)
parser.add_argument('--psql', default='psql')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
dbname = 'inventory_v2_verify_' + uuid.uuid4().hex
env = dict(os.environ, PGHOST='127.0.0.1', PGPORT=str(args.port), PGUSER='postgres', PGCONNECT_TIMEOUT='5')
def sql(database, *, file=None, command=None):
    cmd = [args.psql, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', database]
    cmd += ['-f', str(root / file)] if file else ['-c', command]
    run = subprocess.run(cmd, env=env, capture_output=True, text=True, encoding='utf-8')
    if run.returncode:
        raise RuntimeError(run.stderr)
    return run.stdout

sql('postgres', command=f'CREATE DATABASE {dbname}')
try:
    sql(dbname, file='supabase/tests/ci_auth_stub.sql')
    sql(dbname, file='supabase/tests/ci_storage_stub.sql')
    migrations = sorted(root.glob('supabase/migrations/*.sql'))
    for migration in migrations:
        if migration.name.endswith('_restaurant_inventory_v2.sql'):
            sql(dbname, file='supabase/tests/fixtures/inventory_v2_legacy.sql')
        sql(dbname, file=migration.relative_to(root))
    print(f'Full schema replay: {len(migrations)} migrations applied')
    sql(dbname, file='supabase/tests/fixtures/inventory_v2_legacy_assertions.sql')
    print('Legacy migration: 8 preservation checks passed')
    # Broad grants intentionally emulate existing Supabase projects and the CI fixture.
    sql(dbname, command='GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO authenticated')
    output = sql(dbname, file='supabase/tests/database/inventory_v2.test.sql')
    tests = re.findall(r'^(?:not )?ok \d+.*$', output, re.MULTILINE)
    plan = re.search(r'^1\.\.(\d+)$', output, re.MULTILINE)
    if not plan or len(tests) != int(plan[1]) or any(t.startswith('not ok') for t in tests):
        raise RuntimeError(output)
    print(f'Inventory transactions/RLS: {len(tests)} assertions passed')
finally:
    # This exact generated name is the only deletion target; never accept a caller DB name.
    sql('postgres', command=f'DROP DATABASE {dbname}')
