-- `lodestar_indexer_daily` must be `lodestar_indexer_deployment_daily` summed, and both must hold every
-- reward and fee event once: the P&L's daily chart, its per-deployment table and Daily Trends read
-- these, and a gap or a double count shows up as revenue that was never paid or was paid twice.
--
-- Expect zero rows. A row names the indexer and the figure that disagrees.
WITH legacy AS (SELECT LOWER("allocationID") AS a FROM staking_legacy__allocation_created),
raw AS (
  SELECT indexer, SUM(r) AS rewards, SUM(f) AS fees FROM (
    SELECT LOWER(indexer) AS indexer, CAST("tokensRewards" AS HUGEINT) AS r, CAST(0 AS HUGEINT) AS f FROM subgraph_service__indexing_rewards_collected
    UNION ALL SELECT LOWER(indexer), CAST(amount AS HUGEINT), 0 FROM rewards__rewards_assigned
    UNION ALL SELECT LOWER(indexer), CAST(amount AS HUGEINT), 0 FROM rewards__horizon_rewards_assigned WHERE LOWER("allocationID") IN (SELECT a FROM legacy)
    UNION ALL SELECT LOWER("serviceProvider"), 0, CAST("tokensCollected" AS HUGEINT) FROM subgraph_service__query_fees_collected
    UNION ALL SELECT LOWER(indexer), 0, CAST(tokens AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT LOWER(indexer), 0, CAST(tokens AS HUGEINT) FROM staking_legacy__allocation_collected
  ) GROUP BY 1
),
by_deployment AS (SELECT indexer, SUM(total_rewards) AS rewards, SUM(fees_gross) AS fees FROM lodestar_indexer_deployment_daily GROUP BY 1),
by_day AS (SELECT indexer, SUM(total_rewards) AS rewards, SUM(fees_gross) AS fees FROM lodestar_indexer_daily GROUP BY 1)
SELECT COALESCE(r.indexer, d.indexer, x.indexer) AS indexer,
       r.rewards AS raw_rewards, d.rewards AS deployment_rewards, x.rewards AS daily_rewards,
       r.fees AS raw_fees, d.fees AS deployment_fees, x.fees AS daily_fees
FROM raw r
FULL OUTER JOIN by_deployment d ON d.indexer = r.indexer
FULL OUTER JOIN by_day x ON x.indexer = COALESCE(r.indexer, d.indexer)
WHERE COALESCE(r.rewards, 0) IS DISTINCT FROM COALESCE(d.rewards, 0)
   OR COALESCE(d.rewards, 0) IS DISTINCT FROM COALESCE(x.rewards, 0)
   OR COALESCE(r.fees, 0) IS DISTINCT FROM COALESCE(d.fees, 0)
   OR COALESCE(d.fees, 0) IS DISTINCT FROM COALESCE(x.fees, 0);
