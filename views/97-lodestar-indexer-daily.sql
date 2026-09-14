-- One row per indexer per UTC day: `lodestar_indexer_deployment_daily` summed over deployments, and
-- nothing else, so the P&L's per-deployment table and its daily totals cannot disagree.
CREATE VIEW lodestar_indexer_daily AS
SELECT indexer,
       day_start,
       SUM(total_rewards)     AS total_rewards,
       SUM(indexer_rewards)   AS indexer_rewards,
       SUM(delegator_rewards) AS delegator_rewards,
       SUM(reward_count)      AS reward_count,
       SUM(fees_gross)        AS fees_gross,
       SUM(fees_curators)     AS fees_curators,
       SUM(fees_protocol)     AS fees_protocol,
       SUM(fees_delegators)   AS fees_delegators,
       SUM(fees_burned)       AS fees_burned,
       SUM(fees_net)          AS fees_net,
       SUM(fee_count)         AS fee_count
FROM lodestar_indexer_deployment_daily
GROUP BY 1, 2;
