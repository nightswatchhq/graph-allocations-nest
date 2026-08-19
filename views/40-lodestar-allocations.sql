-- Lodestar's `SubgraphAllocation` shape, served from events instead of the gateway (RFC-0011).
--
-- Maps one-for-one onto the interface at `lodestar/src/lib/ingest/allocations.ts:7`, so the route can
-- read this and stop calling `subgraphQuery`. Twelve of its thirteen fields come from two contracts;
-- the thirteenth is noted below and is the only thing this view guesses at, which it refuses to do.
CREATE VIEW lodestar_allocations AS
WITH created AS (
  SELECT "allocationId"           AS id,
         indexer,
         "subgraphDeploymentId"   AS subgraph_deployment,
         CAST(tokens AS HUGEINT)  AS allocated_tokens,
         CAST("currentEpoch" AS HUGEINT) AS created_at_epoch,
         block_timestamp          AS created_at,
         block_number             AS created_at_block
  FROM subgraph_service__allocation_created
),
-- `AllocationResized` changes the stake without opening or closing anything, so the current size is
-- the newest resize if there is one and the creation amount otherwise.
resized AS (
  SELECT "allocationId" AS id,
         CAST("newTokens" AS HUGEINT) AS allocated_tokens,
         ROW_NUMBER() OVER (PARTITION BY "allocationId" ORDER BY block_number DESC, log_index DESC) AS rn
  FROM subgraph_service__allocation_resized
),
closed AS (
  SELECT "allocationId"  AS id,
         block_timestamp AS closed_at,
         block_number    AS closed_at_block,
         "forceClosed"   AS force_closed
  FROM subgraph_service__allocation_closed
),
-- The POI lives here, not on `AllocationClosed` - which is where the subgraph's shape implies it
-- should be. Rewards are collected on close, so this is also the closest thing to a closing epoch.
rewards AS (
  SELECT "allocationId" AS id,
         poi,
         CAST("tokensRewards" AS HUGEINT) AS indexing_rewards,
         CAST("currentEpoch" AS HUGEINT)  AS rewards_epoch,
         ROW_NUMBER() OVER (PARTITION BY "allocationId" ORDER BY block_number DESC, log_index DESC) AS rn
  FROM subgraph_service__indexing_rewards_collected
),
fees AS (
  SELECT "allocationId" AS id, SUM(CAST("tokensCollected" AS HUGEINT)) AS query_fees_collected
  FROM subgraph_service__query_fees_collected GROUP BY 1
),
signal AS (
  SELECT dep, SUM(tok) AS signalled_tokens FROM (
    SELECT "subgraphDeploymentID" AS dep,  CAST(tokens AS HUGEINT) AS tok FROM curation__signalled
    UNION ALL
    SELECT "subgraphDeploymentID" AS dep, -CAST(tokens AS HUGEINT) AS tok FROM curation__burned
  ) GROUP BY 1
)
SELECT c.id,
       c.indexer,
       c.subgraph_deployment,
       COALESCE(s.signalled_tokens, 0)              AS signalled_tokens,
       COALESCE(r.allocated_tokens, c.allocated_tokens) AS allocated_tokens,
       c.created_at_epoch,
       c.created_at,
       cl.closed_at,
       -- The one field nothing carries. `AllocationClosed` has no epoch, so this is the epoch the
       -- rewards were collected in - which for a normal close is the same block. It is NULL rather
       -- than a guess when an allocation closed without collecting rewards.
       CASE WHEN cl.id IS NULL THEN NULL ELSE rw.rewards_epoch END AS closed_at_epoch,
       rw.poi,
       COALESCE(rw.indexing_rewards, 0)             AS indexing_rewards,
       COALESCE(f.query_fees_collected, 0)          AS query_fees_collected,
       CASE WHEN cl.id IS NULL THEN 'Active' ELSE 'Closed' END AS status,
       cl.force_closed,
       c.created_at_block,
       cl.closed_at_block
FROM created c
LEFT JOIN (SELECT * FROM resized WHERE rn = 1) r  ON r.id  = c.id
LEFT JOIN closed cl                                ON cl.id = c.id
LEFT JOIN (SELECT * FROM rewards WHERE rn = 1) rw  ON rw.id = c.id
LEFT JOIN fees f                                   ON f.id  = c.id
LEFT JOIN signal s                                 ON s.dep = c.subgraph_deployment;
