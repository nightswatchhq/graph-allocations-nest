#!/usr/bin/env python3
"""Check every view in views/ against stub tables built from schema.json, in the DuckDB CLI.

Two passes. First every view is created and SELECTed with LIMIT 0, which catches a wrong column or
table. Then a synthetic delegator position is inserted and `lodestar_delegator_stakes` is compared
with hand-computed figures, because the exchange-rate fold is arithmetic no contract can check and a
LIMIT 0 cannot see a runtime type error inside a lambda (a bare `0.0` struct literal was a
DECIMAL(2,1) and the fold failed only with rows present). Usage: python3 scripts/check-views.py [dir]

Parse-check graph-allocations-nest views against stub tables built from schema.json, in DuckDB.
Every table gets the six implicit columns plus its event columns; storage types follow schema.json
so CASTs and comparisons behave as they will on the nest. Then every views/*.sql is applied in name
order and each CREATE VIEW is SELECTed with LIMIT 0, so a bad column name or a type error surfaces
here rather than on the box."""
import json, glob, re, subprocess, sys, os
root = sys.argv[1] if len(sys.argv) > 1 else '.'
s = json.load(open(os.path.join(root, 'schema.json')))
tabs = s.get('tables') or s
items = tabs.items() if isinstance(tabs, dict) else [((t.get('table') or t.get('name')), t) for t in tabs]
def ty(c):
    st = c.get('storage', ''); sol = c.get('sol_type', '')
    if st == 'u64' or sol.startswith('uint8') or sol.startswith('uint16') or sol.startswith('uint32') or sol.startswith('uint64'): return 'BIGINT'
    if sol == 'bool' or st == 'bool': return 'BOOLEAN'
    if st in ('u128','u256','i256','decimal','numeric') or sol.startswith(('uint','int')): return 'HUGEINT'
    return 'VARCHAR'
ddl = []
for name, t in items:
    cols = t.get('columns') if isinstance(t, dict) else []
    defs = []
    for c in cols:
        if isinstance(c, dict): defs.append(f'"{c["name"]}" {ty(c)}')
        else: defs.append(f'"{c}" VARCHAR')
    ddl.append(f'CREATE TABLE "{name}" ({", ".join(defs)});')
sql = "\n".join(ddl) + "\n"
views = sorted(glob.glob(os.path.join(root, 'views', '*.sql')))
names = []
for v in views:
    body = open(v).read()
    sql += f"\n-- {os.path.basename(v)}\n" + body + "\n"
    names += re.findall(r'CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+(\w+)', body, re.I)
for n in names: sql += f'SELECT * FROM {n} LIMIT 0;\n'
r = subprocess.run(['duckdb', ':memory:'], input=sql, capture_output=True, text=True)
print(f"{len(ddl)} stub tables, {len(views)} view files, {len(names)} views: {', '.join(names)}")
if r.returncode != 0 or 'Error' in r.stderr:
    print(r.stderr.strip()[:3000]); sys.exit(1)
print("ALL VIEWS PARSE AND RESOLVE")

# --- pass two: the delegator fold against a hand-computed position -------------------------------
cols={(t.get('table') or t.get('name')):[(c['name'],ty(c)) for c in t['columns']] for t in tabs if isinstance(t,dict)}
W=10**18
def ins(table, **vals):
    row=[]
    for c,t in cols[table]:
        v=vals.get(c, {'block_number':1,'block_hash':'h','block_timestamp':1000,'tx_hash':'t','log_index':0,'address':'a','_seq':1}.get(c, 0 if t in('BIGINT','HUGEINT') else ('false' if t=='BOOLEAN' else 'x')))
        row.append(str(v) if t in ('BIGINT','HUGEINT','BOOLEAN') else f"'{v}'")
    return f'INSERT INTO "{table}" VALUES ({", ".join(row)});'
# delegate 100 for 100 shares; undelegate 50 shares for 60 (realized 10); delegate 30 for 25 shares
# (rate (1*50+30)/75 = 1.0667); undelegate 75 shares for 90 (realized 10); withdraw 60 (locked 90).
data="\n".join([
 ins('staking__horizon_stake_deposited', block_number=1, block_timestamp=1000, serviceProvider='0xI', tokens=1000*W),
 ins('staking__tokens_delegated',   block_number=1, log_index=1, block_timestamp=1001, serviceProvider='0xI', verifier='0xV', delegator='0xD', tokens=100*W, shares=100*W),
 ins('staking__tokens_undelegated', block_number=2, block_timestamp=1002, serviceProvider='0xI', verifier='0xV', delegator='0xD', tokens=60*W, shares=50*W),
 ins('staking__tokens_delegated',   block_number=3, block_timestamp=1003, serviceProvider='0xI', verifier='0xV', delegator='0xD', tokens=30*W, shares=25*W),
 ins('staking__tokens_undelegated', block_number=4, block_timestamp=1004, serviceProvider='0xI', verifier='0xV', delegator='0xD', tokens=90*W, shares=75*W),
 ins('staking__delegated_tokens_withdrawn', block_number=5, block_timestamp=1005, serviceProvider='0xI', verifier='0xV', delegator='0xD', tokens=60*W),
 ins('staking__thaw_request_created', block_number=4, log_index=1, block_timestamp=1004, requestType=1, serviceProvider='0xI', verifier='0xV', owner='0xD', shares=75*W, thawingUntil=1234567890, thawRequestId='0xreq', nonce=1),
])
q = ("SELECT CAST(share_amount AS VARCHAR), round(personal_exchange_rate, 6), CAST(realized_rewards // 1000000000000000000 AS VARCHAR), "
     "CAST(total_delegated_tokens // 1000000000000000000 AS VARCHAR), CAST(total_undelegated_tokens // 1000000000000000000 AS VARCHAR), "
     "CAST(locked_tokens // 1000000000000000000 AS VARCHAR), locked_until, active FROM lodestar_delegator_stakes;")
r = subprocess.run(['duckdb', ':memory:', '-csv', '-noheader'], input=sql + "\n" + data + "\n" + q, capture_output=True, text=True)
got = r.stdout.strip().split("\n")[-1] if r.stdout.strip() else ''
want = "0,1.066667,20,130,150,90,1234567890,false"
if r.returncode != 0 or got != want:
    print("DELEGATOR FOLD WRONG\n  want", want, "\n  got ", got, "\n", r.stderr.strip()[:800]); sys.exit(1)
print("DELEGATOR FOLD MATCHES THE HAND-COMPUTED POSITION")
