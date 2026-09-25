-- One row per indexer, deployment and UTC day: indexing rewards split between the indexer and its
-- delegators, and query fees taken apart the way the contracts took them. The definition behind
-- Lodestar's P&L and Daily Trends (nightswatchhq/lodestar#228); `lodestar_indexer_daily` is its sum.
--
-- Dated by the event that paid, never by allocation close: Horizon collects on every POI, so an
-- allocation can be paid for months before it closes, and a close-dated series books it all on one day.
--
-- Rewards are `IndexingRewardsCollected`, legacy `RewardsAssigned`, and `HorizonRewardsAssigned` on
-- legacy allocations only. On a Horizon allocation `HorizonRewardsAssigned` fires in the same
-- transaction as `IndexingRewardsCollected` for the same amount (235,408 of 235,408 pairs on the live
-- nest, 2026-09-13), so taking both counts every Horizon reward twice.
--
-- Query fees, Horizon: `GraphPayments.collect` takes the protocol cut rounded up, then the data
-- service's cut of the remainder rounded up (which SubgraphService forwards to curation and reports as
-- `tokensCurators`), then, when the pool has shares, the delegation fee cut of what is left rounded up.
-- The indexer gets the rest. `fees_net` is that rest. Checked against `GraphPaymentCollected` receipts.
-- Legacy rebates state it outright: `queryRebates` is emitted after the delegators' share is taken, and
-- whatever the exponential rebate withheld was burned. `AllocationCollected` predates both and pays at
-- a later claim, so its net and delegator figures are NULL rather than guessed.
CREATE VIEW lodestar_indexer_deployment_daily AS
-- `PROTOCOL_PAYMENT_CUT` is immutable in GraphPayments, so the newest sample is every collection's cut.
-- Decoded here rather than read from `lodestar_network_params`, which has no row until an epoch length
-- update exists. No sample leaves the protocol cut, and so the net, NULL rather than an assumed 1%.
WITH protocol_cut AS (
  -- The newest sample's last 32 hex characters folded base-16: the sum `list_reduce(..., acc * 16 + d)`
  -- computes, written out as `lodestar_network_params` has it, for engines without list comprehensions.
  SELECT
         CAST(strpos('0123456789abcdef', substr(h, 1, 1)) - 1 AS HUGEINT) * CAST('21267647932558653966460912964485513216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 2, 1)) - 1 AS HUGEINT) * CAST('1329227995784915872903807060280344576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 3, 1)) - 1 AS HUGEINT) * CAST('83076749736557242056487941267521536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 4, 1)) - 1 AS HUGEINT) * CAST('5192296858534827628530496329220096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 5, 1)) - 1 AS HUGEINT) * CAST('324518553658426726783156020576256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 6, 1)) - 1 AS HUGEINT) * CAST('20282409603651670423947251286016' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 7, 1)) - 1 AS HUGEINT) * CAST('1267650600228229401496703205376' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 8, 1)) - 1 AS HUGEINT) * CAST('79228162514264337593543950336' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 9, 1)) - 1 AS HUGEINT) * CAST('4951760157141521099596496896' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 10, 1)) - 1 AS HUGEINT) * CAST('309485009821345068724781056' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 11, 1)) - 1 AS HUGEINT) * CAST('19342813113834066795298816' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 12, 1)) - 1 AS HUGEINT) * CAST('1208925819614629174706176' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 13, 1)) - 1 AS HUGEINT) * CAST('75557863725914323419136' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 14, 1)) - 1 AS HUGEINT) * CAST('4722366482869645213696' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 15, 1)) - 1 AS HUGEINT) * CAST('295147905179352825856' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 16, 1)) - 1 AS HUGEINT) * CAST('18446744073709551616' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 17, 1)) - 1 AS HUGEINT) * CAST('1152921504606846976' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 18, 1)) - 1 AS HUGEINT) * CAST('72057594037927936' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 19, 1)) - 1 AS HUGEINT) * CAST('4503599627370496' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 20, 1)) - 1 AS HUGEINT) * CAST('281474976710656' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 21, 1)) - 1 AS HUGEINT) * CAST('17592186044416' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 22, 1)) - 1 AS HUGEINT) * CAST('1099511627776' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 23, 1)) - 1 AS HUGEINT) * CAST('68719476736' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 24, 1)) - 1 AS HUGEINT) * CAST('4294967296' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 25, 1)) - 1 AS HUGEINT) * CAST('268435456' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 26, 1)) - 1 AS HUGEINT) * CAST('16777216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 27, 1)) - 1 AS HUGEINT) * CAST('1048576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 28, 1)) - 1 AS HUGEINT) * CAST('65536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 29, 1)) - 1 AS HUGEINT) * CAST('4096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 30, 1)) - 1 AS HUGEINT) * CAST('256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 31, 1)) - 1 AS HUGEINT) * CAST('16' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 32, 1)) - 1 AS HUGEINT) * CAST('1' AS HUGEINT) AS ppm
  FROM (SELECT right(lower(CAST(result AS VARCHAR)), 32) AS h
        FROM protocol_payment_cut WHERE reverted = false ORDER BY block_number DESC LIMIT 1)
),
-- The pool SubgraphService pays into is the legacy pool, so both eras' shares count, and every Horizon
-- delegation on this nest names SubgraphService as its verifier.
pool_shares AS (
  SELECT sp, k, SUM(sh) OVER (PARTITION BY sp ORDER BY k ROWS UNBOUNDED PRECEDING) AS cum_shares FROM (
    SELECT LOWER(indexer) AS sp, block_number * 100000 + log_index AS k,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index,  CAST(shares AS HUGEINT) FROM staking__tokens_delegated
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking__tokens_undelegated
  )
),
-- Query fees are payment type 0. No `DelegationFeeCutSet` means the stored cut is zero.
query_fee_cuts AS (
  SELECT LOWER("serviceProvider") AS sp, CAST("feeCut" AS HUGEINT) AS cut, block_number * 100000 + log_index AS k
  FROM staking__delegation_fee_cut_set
  WHERE CAST("paymentType" AS BIGINT) = 0 AND LOWER(verifier) = '0xb2bb92d0de618878e438b55d5846cfecd9301105'
),
legacy_deployment AS (
  SELECT LOWER("allocationID") AS a, LOWER("subgraphDeploymentID") AS dep FROM staking_legacy__allocation_created
),
legacy_rewards AS (
  SELECT r.sp, r.dep, r.ts, r.amount, COALESCE(l.pool_delta, 0) AS to_delegators
  FROM (
    SELECT LOWER(ra.indexer) AS sp, d.dep, CAST(ra.block_timestamp AS BIGINT) AS ts, ra.block_number * 100000 + ra.log_index AS k, CAST(ra.amount AS HUGEINT) AS amount
    FROM rewards__rewards_assigned ra LEFT JOIN legacy_deployment d ON d.a = LOWER(ra."allocationID")
    UNION ALL
    SELECT LOWER(h.indexer), d.dep, CAST(h.block_timestamp AS BIGINT), h.block_number * 100000 + h.log_index, CAST(h.amount AS HUGEINT)
    FROM rewards__horizon_rewards_assigned h JOIN legacy_deployment d ON d.a = LOWER(h."allocationID")
  ) r
  LEFT JOIN lodestar_indexer_ledger l
    ON l.indexer = r.sp AND l.k = r.k AND l.kind IN ('legacy_reward_share', 'legacy_path_share')
),
horizon_fees AS (
  SELECT q.sp, q.dep, q.ts, q.gross, q.curators, q.protocol,
         CASE WHEN COALESCE(ps.cum_shares, 0) > 0
              THEN (q.gross - q.protocol - q.curators) - (q.gross - q.protocol - q.curators) * (1000000 - COALESCE(c.cut, 0)) // 1000000
              ELSE 0 END AS delegators
  -- The cut and the pool shares in force at each collection: the newest `query_fee_cuts` and
  -- `pool_shares` rows at or before its key. That was `ASOF LEFT JOIN`, which only DuckDB spells; as in
  -- `lodestar_indexer_ledger`, each newest key is carried forward over the three streams in key order,
  -- a change at the collection's own key sorting first as `>=` had it, and the collection joins on
  -- that exact key. `k` is unique per event.
  FROM (
    SELECT sp, dep, ts, gross, curators, protocol, ck, pk FROM (
      SELECT sp, dep, ts, gross, curators, protocol, src,
             MAX(CASE WHEN src = 0 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS ck,
             MAX(CASE WHEN src = 1 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS pk
      FROM (
        SELECT sp, k, 0 AS src, CAST(NULL AS VARCHAR) AS dep, CAST(NULL AS BIGINT) AS ts,
               CAST(NULL AS HUGEINT) AS gross, CAST(NULL AS HUGEINT) AS curators, CAST(NULL AS HUGEINT) AS protocol
        FROM query_fee_cuts
        UNION ALL SELECT sp, k, 1, CAST(NULL AS VARCHAR), CAST(NULL AS BIGINT), CAST(NULL AS HUGEINT), CAST(NULL AS HUGEINT), CAST(NULL AS HUGEINT)
        FROM pool_shares
        UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index, 2, LOWER("subgraphDeploymentId"),
               CAST(block_timestamp AS BIGINT),
               CAST("tokensCollected" AS HUGEINT), CAST("tokensCurators" AS HUGEINT),
               CAST("tokensCollected" AS HUGEINT)
                 - CAST("tokensCollected" AS HUGEINT) * (1000000 - (SELECT ppm FROM protocol_cut)) // 1000000
        FROM subgraph_service__query_fees_collected
      )
    ) WHERE src = 2
  ) q
  LEFT JOIN query_fee_cuts c ON c.sp = q.sp AND c.k = q.ck
  LEFT JOIN pool_shares ps ON ps.sp = q.sp AND ps.k = q.pk
),
events AS (
  SELECT LOWER(indexer) AS indexer, LOWER("subgraphDeploymentId") AS deployment, CAST(block_timestamp AS BIGINT) AS ts,
         CAST("tokensRewards" AS HUGEINT) AS total, CAST("tokensIndexerRewards" AS HUGEINT) AS to_indexer,
         CAST("tokensDelegationRewards" AS HUGEINT) AS to_delegators, 1 AS rewarded,
         CAST(0 AS HUGEINT) AS gross, CAST(0 AS HUGEINT) AS curators, CAST(0 AS HUGEINT) AS protocol,
         CAST(0 AS HUGEINT) AS fee_delegators, CAST(0 AS HUGEINT) AS burned, CAST(0 AS HUGEINT) AS net, 0 AS collected
  FROM subgraph_service__indexing_rewards_collected
  UNION ALL SELECT sp, dep, ts, amount, amount - to_delegators, to_delegators, 1, 0, 0, 0, 0, 0, 0, 0 FROM legacy_rewards
  UNION ALL SELECT sp, dep, ts, 0, 0, 0, 0, gross, curators, protocol, delegators, 0, gross - protocol - curators - delegators, 1 FROM horizon_fees
  UNION ALL SELECT LOWER(indexer), LOWER("subgraphDeploymentID"), CAST(block_timestamp AS BIGINT), 0, 0, 0, 0,
         CAST(tokens AS HUGEINT), CAST("curationFees" AS HUGEINT), CAST("protocolTax" AS HUGEINT),
         CAST("delegationRewards" AS HUGEINT),
         CAST("queryFees" AS HUGEINT) - CAST("queryRebates" AS HUGEINT) - CAST("delegationRewards" AS HUGEINT),
         CAST("queryRebates" AS HUGEINT), 1
  FROM staking_legacy__rebate_collected
  UNION ALL SELECT LOWER(indexer), LOWER("subgraphDeploymentID"), CAST(block_timestamp AS BIGINT), 0, 0, 0, 0,
         CAST(tokens AS HUGEINT), CAST("curationFees" AS HUGEINT),
         CAST(tokens AS HUGEINT) - CAST("curationFees" AS HUGEINT) - CAST("rebateFees" AS HUGEINT),
         NULL, 0, NULL, 1
  FROM staking_legacy__allocation_collected
)
SELECT indexer,
       deployment,
       ts // 86400 * 86400  AS day_start,
       SUM(total)           AS total_rewards,
       SUM(to_indexer)      AS indexer_rewards,
       SUM(to_delegators)   AS delegator_rewards,
       SUM(rewarded)        AS reward_count,
       SUM(gross)           AS fees_gross,
       SUM(curators)        AS fees_curators,
       SUM(protocol)        AS fees_protocol,
       SUM(fee_delegators)  AS fees_delegators,
       SUM(burned)          AS fees_burned,
       SUM(net)             AS fees_net,
       SUM(collected)       AS fee_count
FROM events
GROUP BY 1, 2, 3;
