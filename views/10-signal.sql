-- Net curation signal per subgraph deployment.
--
-- Signal is cumulative: shares are minted by `Signalled` and destroyed by `Burned`, so the current
-- holding is the difference and needs the full history since the L2 deployment. `tokens` is GRT paid
-- in; `signal` is the bonding-curve share minted for it. The two are not interchangeable - GRT
-- returned on a burn is not the GRT that went in - so the conserved quantity to filter on is signal,
-- and GRT is carried alongside as a sense of scale only.
CREATE VIEW deployment_signal AS
WITH minted AS (
  SELECT "subgraphDeploymentID" AS deployment_id,
         SUM(CAST(signal AS HUGEINT)) AS signal_minted,
         SUM(CAST(tokens AS HUGEINT)) AS grt_signalled,
         COUNT(DISTINCT curator)     AS curators
  FROM curation__signalled GROUP BY 1
),
burned AS (
  SELECT "subgraphDeploymentID" AS deployment_id,
         SUM(CAST(signal AS HUGEINT)) AS signal_burned
  FROM curation__burned GROUP BY 1
)
SELECT m.deployment_id,
       m.signal_minted - COALESCE(b.signal_burned, 0) AS net_signal,
       m.grt_signalled,
       m.curators
FROM minted m LEFT JOIN burned b ON b.deployment_id = m.deployment_id;
