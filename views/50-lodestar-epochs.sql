-- Lodestar's `SubgraphEpoch` shape (RFC-0011), served from events.
--
-- **The trap this view exists to avoid.** `EpochManager.epochLength` is 7,200, and the obvious move is
-- `start_block = anchor + (epoch - anchor_epoch) * 7200`. That is wrong on Arbitrum, and wrong by a
-- factor of ~48: inside an Arbitrum contract `block.number` returns the **L1** block number, so
-- EpochManager counts epochs in L1 blocks, while the `block_number` on an indexed log is **L2**.
-- Computing it gave 60,142 epochs where the network has 1,356.
--
-- `EpochRun` cannot rescue it either - it has fired **once** in the entire history, because running an
-- epoch is optional and nobody bothers.
--
-- So boundaries are derived from what the events themselves report. `AllocationCreated` and
-- `IndexingRewardsCollected` both carry `currentEpoch` alongside their L2 block, which is a direct
-- (epoch, L2 block) observation and needs no L1/L2 mapping at all. Our max epoch from these is 1,356,
-- which is exactly what the network subgraph reports.
CREATE VIEW epoch_boundaries AS
WITH observed AS (
  SELECT CAST("currentEpoch" AS HUGEINT) AS epoch, block_number
  FROM subgraph_service__allocation_created
  UNION ALL
  SELECT CAST("currentEpoch" AS HUGEINT), block_number
  FROM subgraph_service__indexing_rewards_collected
),
per_epoch AS (
  SELECT epoch, MIN(block_number) AS first_seen, MAX(block_number) AS last_seen
  FROM observed GROUP BY 1
)
SELECT epoch,
       first_seen AS start_block,
       -- An epoch ends where the next one is first seen. The newest epoch has no successor yet, so it
       -- runs to its own last observation - open-ended rather than wrong.
       COALESCE(LEAD(first_seen) OVER (ORDER BY epoch) - 1, last_seen) AS end_block,
       last_seen,
       -- **The width of the uncertainty, exposed rather than implied.** An epoch's true start lies
       -- somewhere between the previous epoch's last observation and this one's first; everything in
       -- that window is attributed to the predecessor by the `end_block` rule above, and the subgraph
       -- may put some of it here instead. This column is that window's size in L2 blocks, so a
       -- consumer can tell a boundary that is nailed down from one that is a few thousand blocks wide.
       --
       -- Measured against the Graph Network subgraph at pinned block 501157502, this is the whole
       -- remaining disagreement in `query_fees_collected` and `signalled_tokens` from epoch 1302 up:
       -- every disagreeing pair is one epoch high and the next equally low, and in every case the
       -- *successor* has query-fee events inside this gap whose value is exactly the delta. Epochs
       -- 1342/1343 differ by ±47343610881192241620730 and 1343 holds 41 such events; 1363/1364 by
       -- ±1016363782691576710331 with 6. Zero exceptions in that window.
       --
       -- A wide gap is a warning, not a verdict: 19 epochs above 1302 have fee events in this window
       -- and only 4 of them disagree, because an event in the gap may genuinely belong to the
       -- predecessor. It bounds the uncertainty, which is the honest thing available without an
       -- L1-to-L2 block mapping. See nightswatchhq/nuthatch#1116.
       COALESCE(first_seen - LAG(last_seen) OVER (ORDER BY epoch) - 1, 0) AS unobserved_gap_blocks,
       -- Honest about what this is: a boundary observed from events, not read off a contract. An
       -- epoch in which nothing happened leaves no row at all, which a consumer must expect.
       'observed' AS boundary_source
FROM per_epoch;

-- The per-epoch totals Lodestar wants. Rewards carry their own epoch; query fees do not, so they are
-- bucketed by block against the boundaries above.
CREATE VIEW lodestar_epochs AS
WITH rewards AS (
  SELECT CAST("currentEpoch" AS HUGEINT) AS epoch,
         SUM(CAST("tokensRewards" AS HUGEINT))           AS total_rewards,
         SUM(CAST("tokensIndexerRewards" AS HUGEINT))    AS total_indexer_rewards,
         SUM(CAST("tokensDelegationRewards" AS HUGEINT)) AS total_delegator_rewards
  FROM subgraph_service__indexing_rewards_collected GROUP BY 1
),
-- `queryFeesCollected` in the network subgraph is **net**, not gross: the curator share and a 1%
-- protocol tax are both taken out, and the tax is truncated **per event** rather than on the epoch
-- total. Summing first and taxing the total is wrong by a few hundred wei per epoch, which is small
-- enough to look like rounding noise and is in fact a different quantity. Integer division is
-- required: DuckDB's `/` returns a DOUBLE and loses precision outright at 1e23.
-- Measured over the 175 closed epochs from 1195 up, this took exact agreement from 0 to 145.
fees AS (
  SELECT b.epoch,
         SUM(CAST(q."tokensCollected" AS HUGEINT)
             - CAST(q."tokensCurators" AS HUGEINT)
             - (CAST(q."tokensCollected" AS HUGEINT) // 100)) AS query_fees_collected,
         SUM(CAST(q."tokensCurators"  AS HUGEINT))            AS curator_query_fees
  FROM subgraph_service__query_fees_collected q
  JOIN epoch_boundaries b
    ON q.block_number >= b.start_block AND q.block_number <= b.end_block
  GROUP BY 1
),
-- `signalledTokens` is **gross signal net of the curation tax**, and burns are not subtracted from
-- it at all. This previously computed `signalled - burned` and ignored `curationTax`, wrong in two
-- directions at once. The tell was that 81 of 266 epochs came out **negative**: a net flow was being
-- compared against something that is not a flow, and a negative token quantity is impossible as the
-- stock the subgraph is reporting. Measured, exact agreement went from 6 of 175 to 165 of 175, and
-- the ten that remain are five adjacent pairs of equal and opposite magnitude - value filed one
-- epoch out by the observed-boundary problem described above, not value lost.
signal AS (
  SELECT b.epoch,
         SUM(CAST(s.tokens AS HUGEINT) - CAST(s."curationTax" AS HUGEINT)) AS signalled_tokens
  FROM curation__signalled s
  JOIN epoch_boundaries b ON s.block_number >= b.start_block AND s.block_number <= b.end_block
  GROUP BY 1
)
SELECT b.epoch                                  AS id,
       b.start_block,
       b.end_block,
       COALESCE(s.signalled_tokens, 0)          AS signalled_tokens,
       COALESCE(r.total_rewards, 0)             AS total_rewards,
       COALESCE(r.total_indexer_rewards, 0)     AS total_indexer_rewards,
       COALESCE(r.total_delegator_rewards, 0)   AS total_delegator_rewards,
       COALESCE(f.query_fees_collected, 0)      AS query_fees_collected,
       COALESCE(f.curator_query_fees, 0)        AS curator_query_fees
FROM epoch_boundaries b
LEFT JOIN rewards r ON r.epoch = b.epoch
LEFT JOIN fees    f ON f.epoch = b.epoch
LEFT JOIN signal  s ON s.epoch = b.epoch
ORDER BY b.epoch;
