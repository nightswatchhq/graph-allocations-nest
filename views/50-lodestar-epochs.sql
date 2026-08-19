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
fees AS (
  SELECT b.epoch,
         SUM(CAST(q."tokensCollected" AS HUGEINT)) AS query_fees_collected,
         SUM(CAST(q."tokensCurators"  AS HUGEINT)) AS curator_query_fees
  FROM subgraph_service__query_fees_collected q
  JOIN epoch_boundaries b
    ON q.block_number >= b.start_block AND q.block_number <= b.end_block
  GROUP BY 1
),
signal AS (
  SELECT b.epoch, SUM(t.tok) AS signalled_tokens
  FROM (
    SELECT block_number, CAST(tokens AS HUGEINT) AS tok FROM curation__signalled
    UNION ALL
    SELECT block_number, -CAST(tokens AS HUGEINT)     FROM curation__burned
  ) t
  JOIN epoch_boundaries b ON t.block_number >= b.start_block AND t.block_number <= b.end_block
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
