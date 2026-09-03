# Graph allocations nest

An installable Nuthatch nest for **Graph Horizon allocations and curation signal** on Arbitrum One.

It exists to answer one question: **which subgraph deployments have curation signal staked on them
and no indexer serving them?** Someone paid to have that data produced and nobody is producing it.

```sh
nuthatch init --from https://github.com/nightswatchhq/graph-allocations-nest
nuthatch dev --dir graph-allocations-nest --rpc https://your-archive-rpc --state-rpc https://your-archive-rpc --window 81920 --seal-direct
nuthatch sql --dir graph-allocations-nest "SELECT * FROM port_queue WHERE net_signal > 1000"
```

An archive RPC is required. `L2Curation` is indexed from its 2022 deployment because signal is
cumulative, and a public endpoint will not serve that range. Run `nuthatch doctor --rpc <url>
--address 0x22d78fb4bc72e191C765807f8891B5e1785C8014` first: its range-only probe recommends a
320-block window, and passing `--address` raised that to 81,920 on the endpoint used here. Taking the
first figure would make the backfill 256 times longer.

## Query surface

- **`lodestar_allocations`** - the `SubgraphAllocation` shape Lodestar's `ingest-allocations` route
  wants (RFC-0011), served from events rather than the gateway. **Verified against the network
  subgraph: 13,301 active allocations on both sides, exact.** 245,372 allocations total, 232,505
  carrying a POI.
- **`lodestar_epochs`** / **`epoch_boundaries`** - per-epoch rewards, fees and signal. Max epoch
  **1,356, matching the network subgraph exactly**. Boundaries are *observed* from the `currentEpoch`
  the events themselves carry, not computed - see the header of `views/50-lodestar-epochs.sql` for
  why computing it is wrong by a factor of 48 on Arbitrum.
- **`lodestar_disputes`** - the dispute lifecycle, with `Undecided` falling out of a LEFT JOIN rather
  than needing a status on chain.
- **`lodestar_escrow_transactions`** - PaymentsEscrow money movements in Lodestar's `PaymentsTx`
  shape. Deposits match the network subgraph **exactly**; collections are a strict superset, and the
  **cause is now established**. Joining on the decoded subgraph id (`txHash || logIndex` as
  little-endian uint32, where its index is ours plus one) matches every subgraph row with **zero**
  subgraph-only rows. The nest-only rows are `EscrowCollected` events where **`payer == collector`**,
  one address collecting from itself, which the subgraph drops. Two further nest rows are `Thaw` and
  `CancelThaw`, types the subgraph's entity does not model at all. See
  nightswatchhq/nuthatch#1114.
- **`port_queue`** - deployments with net signal and no open allocation, ranked. No threshold applied;
  the caller filters (see below).
- **`deployment_signal`** - net curation signal per deployment, with GRT paid in and curator count.
- **`open_allocations`** - allocations currently open per deployment, with indexer count.

## Contracts

Eleven declarations on Arbitrum One, plus one pinned `eth_call`. Every address is from
`graphprotocol/contracts` `addresses.json` (key `42161`) and every start block was found by binary
search on `eth_getCode` against an archive RPC. The two staking rows are the **same proxy**: Horizon
renamed every staking event, so the pre-Horizon shapes are decoded through a second ABI rather than
lost (see the comments in `nuthatch.toml`).

| Alias | Contract | Address | From block |
| --- | --- | --- | --- |
| `subgraph_service` | SubgraphService | `0xb2bb92d0de618878e438b55d5846cfecd9301105` | 397,492,865 |
| `curation` | L2Curation | `0x22d78fb4bc72e191c765807f8891b5e1785c8014` | 42,449,403 |
| `epochs` | EpochManager | `0x5a843145c43d328b9bb7a4401d94918f131bb281` | 42,449,227 |
| `disputes` | DisputeManager (Horizon) | `0x2fe023a575449acb698648ed21276293fa176f96` | 397,492,858 |
| `escrow` | PaymentsEscrow | `0xf6fcc27aaf1fcd8b254498c9794451d82afc673e` | 397,491,106 |
| `staking` | HorizonStaking, Horizon ABI | `0x00669a4cf01450b64e8a2a20e9b1fcb71e61ef03` | 42,449,585 |
| `staking_legacy` | the same proxy, pre-Horizon ABI | `0x00669a4cf01450b64e8a2a20e9b1fcb71e61ef03` | 42,449,585 |
| `gns` | L2GNS | `0xec9a7fb6cbc2e41926127929c2dce6e9c5d33bec` | 42,449,510 |
| `service_registry` | ServiceRegistry | `0x072884c745c0a23144753335776c99be22588f8a` | 42,449,357 |
| `rewards` | RewardsManager | `0x971b9d3d0ae3eca029cab5ea1fb0f72c85e6a525` | 42,449,638 |
| `tally` | GraphTallyCollector | `0x8f69f5c07477ac46fbc491b1e6d91e2bb0111a9e` | 399,496,057 |

The `[[calls]]` entry (`grt_total_supply`, a pinned `totalSupply()` on L2GraphToken every 100,000
blocks) needs historical `eth_call`, so **the nest refuses to start without `--state-rpc`**. That is
deliberate and it is not a `nuthatch.toml` field, because an archive endpoint usually carries a key
and the config is pinned into the nest's content address. A deploy that forgets the flag crash-loops
with a message saying exactly this; it happened on 2026-09-03.

Three table names will surprise anyone writing a view, and they are all correct:

- `AllocationClosed` on legacy staking and `RewardsDenied` on the rewards manager are **topic0
  overloads** across the Horizon upgrade, and both halves fired on chain. nuthatch keeps both and
  suffixes the tables with the first two bytes of topic0: `staking_legacy__allocation_closed_7203`
  (9 arguments, to block 129,795,275) and `_f672` (8 arguments, since); `rewards__rewards_denied_07b6`
  (legacy, with `epoch`) and `_9b13` (Horizon).
- `RAVCollected` becomes **`tally__r_a_v_collected`**: the snake_case split does not know an acronym
  when it sees one.

## Filter honestly, or the queue is a haystack

Measured on a full backfill, 2026-08-19:

| Population | Count |
|---|---:|
| Deployments ever signalled | 13,881 |
| Still carrying net signal | 7,621 |
| With an open allocation | 6,781 |
| **Signalled and unserved** | **3,853** |
| **Signalled > 1,000 and unserved** | **63** |

`net_signal > 0` alone returns over half of everything ever signalled. The threshold is not
decoration. `checks/` pins these numbers, so `nuthatch check` fails loudly if the join ever breaks.

## What this nest does not tell you

- **Unserved, never unhealthy.** Indexing lag and gateway QoS are off-chain; no contract emits them.
  A deployment with a healthy-looking allocation may be served by an indexer weeks behind.
- **Deployment IDs, not names.** Subgraph display names live in IPFS-pinned JSON behind the GNS.
- **`LegacyAllocationMigrated` has fired zero times.** The event exists in the ABI and has never been
  emitted, so the pre-Horizon migration path is invisible here. "No open allocation on
  `SubgraphService`" equals "unserved" only if every live allocation now lives on `SubgraphService`.
  13,306 open allocations is a plausible network-wide figure, which supports that, but it is inference.
- **A single curator is not demand.** `port_queue` carries a `curators` count for a reason - much of
  the top of the list is one address, and a repeating 10,000 GRT / 9,900 signal shape runs through the
  middle, which is programmatic rather than anybody deciding a dataset matters. Read before believing.

## The staged upgrade

`graphprotocol/contracts` carries a `pendingImplementation` on every Horizon contract, all deployed
2026-07-23. Diffed rather than assumed: **`L2Curation` is unchanged**, and on `SubgraphService`
`AllocationCreated`, `AllocationClosed` and `AllocationResized` all survive untouched. What moves is
`LegacyAllocationMigrated`, `StakeClaimLocked` and `StakeClaimReleased` disappearing, two directory
events changing arity, and `POIPresented` arriving.

**Vendor the current ABI, never the pending one** - the current ABI is what decodes the history.
`POIPresented` is worth adding after the upgrade executes, not before.
