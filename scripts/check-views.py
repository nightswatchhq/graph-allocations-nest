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
 # a second pool at real-world scale: a 15,572 GRT position beside a 1,024,858 GRT one. shares * pool_tokens
 # is 1.6e46 and overflowed INT128 on 8107 before staked_tokens split its whole-share part from the remainder.
 ins('staking__horizon_stake_deposited', block_number=1, log_index=5, block_timestamp=1000, serviceProvider='0xJ', tokens=100000*W),
 ins('staking__tokens_delegated', block_number=6, block_timestamp=1006, serviceProvider='0xJ', verifier='0xV', delegator='0xE', tokens=15572*W, shares=15572*W),
 ins('staking__tokens_delegated', block_number=6, log_index=1, block_timestamp=1006, serviceProvider='0xJ', verifier='0xV', delegator='0xF', tokens=1024858*W, shares=1024858*W),
])
q = ("SELECT CAST(share_amount AS VARCHAR), round(personal_exchange_rate, 6), CAST(realized_rewards // 1000000000000000000 AS VARCHAR), "
     "CAST(total_delegated_tokens // 1000000000000000000 AS VARCHAR), CAST(total_undelegated_tokens // 1000000000000000000 AS VARCHAR), "
     "CAST(locked_tokens // 1000000000000000000 AS VARCHAR), locked_until, active FROM lodestar_delegator_stakes WHERE indexer = '0xi';")
r = subprocess.run(['duckdb', ':memory:', '-csv', '-noheader'], input=sql + "\n" + data + "\n" + q, capture_output=True, text=True)
got = r.stdout.strip().split("\n")[-1] if r.stdout.strip() else ''
want = "0,1.066667,20,130,150,90,1234567890,false"
if r.returncode != 0 or got != want:
    print("DELEGATOR FOLD WRONG\n  want", want, "\n  got ", got, "\n", r.stderr.strip()[:800]); sys.exit(1)
print("DELEGATOR FOLD MATCHES THE HAND-COMPUTED POSITION")
q2 = "SELECT delegator, CAST(round(staked_tokens / 1000000000000000000) AS BIGINT) FROM lodestar_delegator_stakes WHERE indexer = '0xj' ORDER BY delegator;"
r = subprocess.run(['duckdb', ':memory:', '-csv', '-noheader'], input=sql + "\n" + data + "\n" + q2, capture_output=True, text=True)
got = r.stdout.strip()
want = "0xe,15572\n0xf,1024858"
if r.returncode != 0 or got != want:
    print("WEI-SCALE STAKE WRONG\n  want", repr(want), "\n  got ", repr(got), "\n", r.stderr.strip()[:800]); sys.exit(1)
print("WEI-SCALE STAKE DOES NOT OVERFLOW AND ROUNDS TO THE CONTRACT'S ANSWER")

# --- pass three: rewards and fees by the event that paid them --------------------------------------
# An allocation collects on days 10 and 11 while open and closes on day 12; a close-dated fold books
# all 150 GRT on day 12. Beside it a zero-reward collection, a legacy allocation paid at close after
# the upgrade, one Horizon fee collection whose split is a real `GraphPaymentCollected` (tx
# 0xef690b73…f2df), and one legacy rebate.
SS = '0xb2bb92d0de618878e438b55d5846cfecd9301105'
DAY = 86400
data3 = "\n".join([
 ins('staking__horizon_stake_deposited', block_number=1, block_timestamp=100, serviceProvider='0xK', tokens=1000*W),
 ins('protocol_payment_cut', block_number=1, log_index=1, block_timestamp=100, result='0x' + '0'*60 + '2710', reverted='false'),
 ins('staking__tokens_delegated', block_number=2, block_timestamp=200, serviceProvider='0xK', verifier=SS, delegator='0xD', tokens=100*W, shares=100*W),
 ins('staking__delegation_fee_cut_set', block_number=3, block_timestamp=300, serviceProvider='0xK', verifier=SS, paymentType=0, feeCut=100000),
 ins('subgraph_service__indexing_rewards_collected', block_number=10, block_timestamp=10*DAY+5, tx_hash='t10', indexer='0xK', allocationId='0xa1', subgraphDeploymentId='0xd1', tokensRewards=100*W, tokensIndexerRewards=60*W, tokensDelegationRewards=40*W, currentEpoch=1),
 ins('rewards__horizon_rewards_assigned', block_number=10, log_index=1, block_timestamp=10*DAY+5, tx_hash='t10', indexer='0xK', allocationID='0xa1', amount=100*W),
 ins('subgraph_service__indexing_rewards_collected', block_number=11, block_timestamp=11*DAY+5, tx_hash='t11', indexer='0xK', allocationId='0xa1', subgraphDeploymentId='0xd1', tokensRewards=50*W, tokensIndexerRewards=30*W, tokensDelegationRewards=20*W, currentEpoch=2),
 ins('rewards__horizon_rewards_assigned', block_number=11, log_index=1, block_timestamp=11*DAY+5, tx_hash='t11', indexer='0xK', allocationID='0xa1', amount=50*W),
 ins('subgraph_service__allocation_closed', block_number=12, block_timestamp=12*DAY+5, indexer='0xK', allocationId='0xa1', subgraphDeploymentId='0xd1', tokens=1000*W, forceClosed='false'),
 ins('subgraph_service__indexing_rewards_collected', block_number=13, block_timestamp=12*DAY+6, tx_hash='t13', indexer='0xK', allocationId='0xa2', subgraphDeploymentId='0xd2', tokensRewards=0, tokensIndexerRewards=0, tokensDelegationRewards=0, currentEpoch=3),
 ins('rewards__horizon_rewards_assigned', block_number=13, log_index=1, block_timestamp=12*DAY+6, tx_hash='t13', indexer='0xK', allocationID='0xa2', amount=0),
 ins('subgraph_service__query_fees_collected', block_number=14, block_timestamp=12*DAY+7, serviceProvider='0xK', payer='0xP', allocationId='0xa1', subgraphDeploymentId='0xd1', tokensCollected=8860352050294604, tokensCurators=877174852979166),
 ins('staking_legacy__allocation_created', block_number=0, block_timestamp=10, indexer='0xL', subgraphDeploymentID='0xd3', epoch=1, tokens=1000*W, allocationID='0xa3'),
 ins('staking_legacy__delegation_parameters_updated', block_number=0, log_index=1, block_timestamp=10, indexer='0xL', indexingRewardCut=600000, queryFeeCut=1000000),
 ins('staking_legacy__stake_delegated', block_number=0, log_index=2, block_timestamp=10, indexer='0xL', delegator='0xD', tokens=10*W, shares=10*W),
 ins('rewards__horizon_rewards_assigned', block_number=20, block_timestamp=13*DAY+5, indexer='0xL', allocationID='0xa3', amount=1000*W),
 ins('staking_legacy__rebate_collected', block_number=21, block_timestamp=13*DAY+6, indexer='0xL', subgraphDeploymentID='0xd3', allocationID='0xa3', epoch=1, tokens=100, protocolTax=1, curationFees=10, queryFees=89, queryRebates=70, delegationRewards=9),
])
cols3 = "indexer, deployment, day_start, total_rewards, indexer_rewards, delegator_rewards, reward_count, fees_gross, fees_curators, fees_protocol, fees_delegators, fees_burned, fees_net, fee_count"
q3 = f"SELECT {cols3} FROM lodestar_indexer_deployment_daily ORDER BY indexer, deployment, day_start;"
r = subprocess.run(['duckdb', ':memory:', '-csv', '-noheader'], input=sql + "\n" + data3 + "\n" + q3, capture_output=True, text=True)
got = r.stdout.strip()
w = str(W)
want = "\n".join([
 f"0xk,0xd1,{10*DAY},{100*W},{60*W},{40*W},1,0,0,0,0,0,0,0",
 f"0xk,0xd1,{11*DAY},{50*W},{30*W},{20*W},1,0,0,0,0,0,0,0",
 f"0xk,0xd1,{12*DAY},0,0,0,0,8860352050294604,877174852979166,88603520502947,789457367681250,0,7105116309131241,1",
 f"0xk,0xd2,{12*DAY},0,0,0,1,0,0,0,0,0,0,0",
 f"0xl,0xd3,{13*DAY},{1000*W},{600*W},{400*W},1,100,10,1,9,10,70,1",
])
if r.returncode != 0 or got != want:
    print("REWARDS AND FEES BY EVENT WRONG\n  want\n" + want + "\n  got\n" + got + "\n", r.stderr.strip()[:1200]); sys.exit(1)
print("REWARDS ARE DATED BY COLLECTION, COUNTED ONCE, AND THE FEE SPLIT MATCHES A REAL RECEIPT TO THE WEI")
q4 = ("SELECT count(*) FROM (SELECT indexer, day_start, SUM(total_rewards) t, SUM(indexer_rewards) i, SUM(fees_net) n, SUM(reward_count) rc, SUM(fee_count) fc "
      "FROM lodestar_indexer_deployment_daily GROUP BY 1, 2) d FULL OUTER JOIN lodestar_indexer_daily x USING (indexer, day_start) "
      "WHERE d.t IS DISTINCT FROM x.total_rewards OR d.i IS DISTINCT FROM x.indexer_rewards OR d.n IS DISTINCT FROM x.fees_net "
      "OR d.rc IS DISTINCT FROM x.reward_count OR d.fc IS DISTINCT FROM x.fee_count;")
r = subprocess.run(['duckdb', ':memory:', '-csv', '-noheader'], input=sql + "\n" + data3 + "\n" + q4, capture_output=True, text=True)
if r.returncode != 0 or r.stdout.strip() != "0":
    print("PER-INDEXER DAILY IS NOT THE SUM OF PER-DEPLOYMENT DAILY\n  got", r.stdout.strip(), r.stderr.strip()[:800]); sys.exit(1)
print("PER-INDEXER DAILY IS THE SUM OF PER-DEPLOYMENT DAILY")
