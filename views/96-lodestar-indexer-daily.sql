-- One row per indexer per UTC day: indexing rewards split between the indexer and its delegators, and
-- query fees gross, to curators, to the protocol and net (nightswatchhq/lodestar#228, the indexer
-- page's Daily Trends). Both are dated by the event that paid them, not by allocation close: Horizon
-- collects rewards on every POI, so a close-dated series moves weeks of rewards onto one day.
--
-- The legacy delegator share is `lodestar_indexer_ledger`'s, joined by event rather than re-derived,
-- so this view and the pool the ledger was measured exact against cannot disagree. A legacy reward
-- with no ledger row paid the delegators nothing (the pool had no shares).
--
-- A union and a GROUP BY rather than a join of two aggregates, so a caller's `indexer = '0x…'`
-- reaches every source table instead of stopping at a COALESCE.
CREATE VIEW lodestar_indexer_daily AS
WITH legacy_rewards AS (
  SELECT r.sp, r.ts, r.amount, COALESCE(l.pool_delta, 0) AS to_delegators
  FROM (
    SELECT LOWER(indexer) AS sp, CAST(block_timestamp AS BIGINT) AS ts, block_number * 100000 + log_index AS k, CAST(amount AS HUGEINT) AS amount FROM rewards__rewards_assigned
    UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number * 100000 + log_index, CAST(amount AS HUGEINT) FROM rewards__horizon_rewards_assigned
  ) r
  LEFT JOIN lodestar_indexer_ledger l
    ON l.indexer = r.sp AND l.k = r.k AND l.kind IN ('legacy_reward_share', 'legacy_path_share')
),
events AS (
  SELECT LOWER(indexer) AS indexer, CAST(block_timestamp AS BIGINT) AS ts,
         CAST("tokensRewards" AS HUGEINT) AS total, CAST("tokensIndexerRewards" AS HUGEINT) AS to_indexer,
         CAST("tokensDelegationRewards" AS HUGEINT) AS to_delegators, 1 AS rewarded,
         CAST(0 AS HUGEINT) AS gross, CAST(0 AS HUGEINT) AS curators, CAST(NULL AS HUGEINT) AS protocol, CAST(0 AS HUGEINT) AS net, 0 AS collected
  FROM subgraph_service__indexing_rewards_collected
  UNION ALL SELECT sp, ts, amount, amount - to_delegators, to_delegators, 1, 0, 0, NULL, 0, 0 FROM legacy_rewards
  -- Three fee mechanisms across the protocol's life, as in `lodestar_epochs`. Only
  -- `QueryFeesCollected` states all four figures; `AllocationCollected` states no protocol tax.
  UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), 0, 0, 0, 0,
         CAST("tokensCollected" AS HUGEINT), CAST("tokensCurators" AS HUGEINT), CAST("tokensCollected" AS HUGEINT) // 100,
         CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100), 1
  FROM subgraph_service__query_fees_collected
  UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), 0, 0, 0, 0,
         CAST(tokens AS HUGEINT), CAST("curationFees" AS HUGEINT), CAST("protocolTax" AS HUGEINT), CAST("queryFees" AS HUGEINT), 1
  FROM staking_legacy__rebate_collected
  UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), 0, 0, 0, 0,
         CAST(tokens AS HUGEINT), CAST("curationFees" AS HUGEINT), NULL, CAST(tokens AS HUGEINT) - CAST("curationFees" AS HUGEINT), 1
  FROM staking_legacy__allocation_collected
)
SELECT indexer,
       ts // 86400 * 86400  AS day_start,
       SUM(total)           AS total_rewards,
       SUM(to_indexer)      AS indexer_rewards,
       SUM(to_delegators)   AS delegator_rewards,
       SUM(rewarded)        AS reward_count,
       SUM(gross)           AS fees_gross,
       SUM(curators)        AS fees_curators,
       SUM(protocol)        AS fees_protocol,
       SUM(net)             AS fees_net,
       SUM(collected)       AS fee_count
FROM events
GROUP BY 1, 2;
