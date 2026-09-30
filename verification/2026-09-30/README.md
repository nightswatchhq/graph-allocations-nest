# Active allocations against the network subgraph, 2026-09-30

At Arbitrum One block 510,395,917, this nest reported 14,415 active allocations on The Graph's
SubgraphService. The Graph Network subgraph reports the same 14,415 at that block, and the two
sorted lists of allocation IDs are identical (`nest-ids.txt`, `sg-ids.txt`, SHA-256
`3d2baf431f63b6762af6f355b26594d2a5456bc61c5b26741e19f2172c6259c6` each).

All time, the nest counts 591,071 allocations on the legacy staking contract, every one closed, and
279,450 on SubgraphService: 870,521, matching the subgraph's `allocationCount` (`sg-net.json`). That
total was compared as a count only. `LegacyAllocationMigrated` has never fired, so no allocation is
counted in both eras.

- Nest NID `4a5fc4e3ff0300043579050d91c8df0442315b137b1c9ab0f7cdb9f43021d164`, nuthatch 3.12.1
- Subgraph deployment `QmR8WQECdNR6TSUf4FfLSFW7D5RDGGkd7F4A6me56pLqJb`, a graft of the network
  subgraph with no indexing errors, queried through a proxy to the gateway, not the canonical
  gateway deployment
- The block was at or below the nest's `sealed_through`, so the nest side read finalised data

## Rerun it

Against a running copy of this nest (`nuthatch dev` serves `/sql` on port 8288 by default) and any
endpoint serving the network subgraph. Both sides take a block, so the result is reproducible for as
long as the block is sealed.

```bash
B=510395917
NEST=http://127.0.0.1:8288
SUBGRAPH=https://network.thenightswatch.dev/graphql   # or a gateway URL with your key

curl -s --get "$NEST/sql" --data-urlencode 'max_rows=50000' --data-urlencode "q=
  SELECT lower(\"allocationId\") id FROM subgraph_service__allocation_created c
  WHERE block_number <= $B
    AND NOT EXISTS (SELECT 1 FROM subgraph_service__allocation_closed x
                    WHERE x.\"allocationId\" = c.\"allocationId\" AND x.block_number <= $B)" \
  | jq -r '.rows[].id' | LC_ALL=C sort > nest-ids.txt

: > sg-ids.txt; last=""
while :; do
  q="{ allocations(first: 1000, orderBy: id, block: {number: $B},
       where: {status: Active, id_gt: \"$last\"}) { id } }"
  page=$(curl -s -A rerun -H 'content-type: application/json' "$SUBGRAPH" \
         -d "$(jq -nc --arg q "$q" '{query: $q}')" | jq -r '.data.allocations[].id')
  [ -z "$page" ] && break
  echo "$page" | tr 'A-Z' 'a-z' >> sg-ids.txt
  last=$(echo "$page" | tail -n 1)
done
LC_ALL=C sort -o sg-ids.txt sg-ids.txt

wc -l nest-ids.txt sg-ids.txt
comm -3 nest-ids.txt sg-ids.txt | wc -l   # 0: nothing on one side only
```

The endpoint refuses a request without a User-Agent, hence `-A`.
