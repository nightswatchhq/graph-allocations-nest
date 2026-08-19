-- Lodestar's dispute surface (RFC-0011), served from events.
--
-- Three creation events for three dispute kinds, and four resolutions. A dispute with no resolution
-- row is undecided, which a LEFT JOIN says without needing a status column on the chain.
CREATE VIEW lodestar_disputes AS
WITH created AS (
  SELECT "disputeId" AS id, indexer, fisherman, CAST(tokens AS HUGEINT) AS deposit,
         'Indexing' AS kind, "allocationId" AS allocation_id, poi,
         CAST("stakeSnapshot" AS HUGEINT) AS stake_snapshot,
         block_number AS created_at_block, block_timestamp AS created_at
  FROM disputes__indexing_dispute_created
  UNION ALL
  SELECT "disputeId", indexer, fisherman, CAST(tokens AS HUGEINT),
         'Query', NULL, "subgraphDeploymentId",
         CAST("stakeSnapshot" AS HUGEINT), block_number, block_timestamp
  FROM disputes__query_dispute_created
),
resolved AS (
  SELECT "disputeId" AS id, 'Accepted' AS status, CAST(tokens AS HUGEINT) AS resolution_tokens,
         block_number AS resolved_at_block, block_timestamp AS resolved_at
  FROM disputes__dispute_accepted
  UNION ALL
  SELECT "disputeId", 'Rejected', CAST(tokens AS HUGEINT), block_number, block_timestamp
  FROM disputes__dispute_rejected
  UNION ALL
  SELECT "disputeId", 'Drawn', CAST(tokens AS HUGEINT), block_number, block_timestamp
  FROM disputes__dispute_drawn
)
SELECT c.id, c.kind, c.indexer, c.fisherman, c.deposit, c.allocation_id, c.poi,
       c.stake_snapshot, c.created_at_block, c.created_at,
       COALESCE(r.status, 'Undecided') AS status,
       r.resolution_tokens, r.resolved_at_block, r.resolved_at
FROM created c
LEFT JOIN resolved r ON r.id = c.id;
