-- Allocations currently open on the SubgraphService data service.
--
-- An allocation is open when it was created and never closed. `AllocationResized` changes the stake
-- on an existing allocation and neither opens nor closes one, so it is deliberately not consulted.
--
-- Caveat worth stating in the view rather than a README nobody opens: this sees only allocations on
-- `SubgraphService`. `LegacyAllocationMigrated` has fired zero times on this contract, so the
-- pre-Horizon migration path is not visible here. "Not open here" equals "unserved" only if every
-- live allocation now lives on SubgraphService.
CREATE VIEW open_allocations AS
SELECT "subgraphDeploymentId"        AS deployment_id,
       COUNT(*)                      AS open_allocations,
       COUNT(DISTINCT indexer)       AS indexers
FROM subgraph_service__allocation_created
WHERE "allocationId" NOT IN (SELECT "allocationId" FROM subgraph_service__allocation_closed)
GROUP BY 1;
