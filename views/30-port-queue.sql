-- The port queue: deployments carrying live curation signal that no indexer is serving.
--
-- Someone has GRT staked on this data and nobody is producing it - a party with a demonstrated
-- financial interest in a dataset they are not receiving. That is a far better queue than
-- "deployments with no allocation", most of which are dead test deployments nobody has revisited.
--
-- No threshold is applied here; the view is the honest population and the caller filters. Measured
-- 2026-08-19 on a full backfill: 13,881 deployments ever signalled, 7,621 still carrying signal,
-- 6,781 with an open allocation, 3,853 signalled-and-unserved. That last number is a haystack. At
-- net_signal > 1,000 it becomes 63, which is a list a person can read. Filter accordingly.
CREATE VIEW port_queue AS
SELECT s.deployment_id,
       CAST(s.net_signal    / 1000000000000000000 AS BIGINT) AS net_signal,
       CAST(s.grt_signalled / 1000000000000000000 AS BIGINT) AS grt_signalled,
       s.curators
FROM deployment_signal s
LEFT JOIN open_allocations o ON o.deployment_id = s.deployment_id
WHERE COALESCE(o.open_allocations, 0) = 0
  AND s.net_signal > 0
ORDER BY s.net_signal DESC;
