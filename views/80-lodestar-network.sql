-- Lodestar's `graphNetwork` singleton (RFC-0011), assembled from events instead of the gateway.
--
-- This is the one module in the migration that is genuinely an *aggregate* rather than a table, which
-- is why it was ranked last. Fourteen protocol-wide numbers, each a fold over a different contract's
-- events, and one that is not derivable at all without indexing millions of token transfers - so that
-- one is a pinned `eth_call` instead (RFC-0023 tier 3, `grt_total_supply`).
CREATE VIEW lodestar_network AS
WITH staked AS (
  -- Netted **per entity** before counting. Counting rows with `t > 0` instead answers "who ever
  -- had an inflow", which is the same set as "who ever appears" - that is why this used to return
  -- n_positive == n_all exactly, a number that agreed with itself and with nothing else.
  SELECT SUM(net) AS total, COUNT(*) AS n_all,
         COUNT(*) FILTER (WHERE net > 0) AS n_positive
  FROM (
    SELECT sp, SUM(t) AS net FROM (
    -- Legacy era. Horizon renamed these wholesale at block ~408,847,369, so both halves are needed
    -- and neither alone is the protocol's history: the Horizon table starts 366M blocks in.
    SELECT indexer AS sp,             CAST(tokens AS HUGEINT) AS t FROM staking_legacy__stake_deposited
    UNION ALL
    SELECT indexer,                  -CAST(tokens AS HUGEINT)      FROM staking_legacy__stake_withdrawn
    UNION ALL
    SELECT "serviceProvider",         CAST(tokens AS HUGEINT)      FROM staking__horizon_stake_deposited
    UNION ALL
    SELECT "serviceProvider",        -CAST(tokens AS HUGEINT)      FROM staking__horizon_stake_withdrawn
    UNION ALL
    -- Slashing, and it is the whole of #649 gap 3. Deposits minus withdrawals left three indexers
    -- holding 97k-247k GRT that the subgraph reports at zero; each had been slashed for *exactly*
    -- its remaining balance, to the decimal. `tokens` is the full amount removed - the `reward`
    -- beside it is the informer's cut of that same sum, not an additional debit, so subtracting
    -- both would double-count.
    --
    -- Legacy only. `ProvisionSlashed` exists on the Horizon ABI and has never fired: 0 logs across
    -- 408,000,000..496,956,109, checked against a control on the same address and range returning
    -- 129,387. The legacy signature had to be confirmed the same way - the first attempt guessed a
    -- five-parameter form, got 0 logs, and that zero looked exactly like an answer.
    SELECT indexer,                  -CAST(tokens AS HUGEINT)      FROM staking_legacy__stake_slashed
    ) GROUP BY 1
  )
),
-- Delegation, across both eras, and the two eras leave the pool at different moments.
--
-- Legacy: undelegating emits `StakeDelegatedLocked`, which burns the shares and moves the tokens out
-- of the pool immediately into a thawing lock; `StakeDelegatedWithdrawn` merely releases what already
-- left. So the legacy subtraction is at *lock*, and subtracting the withdrawal instead would
-- double-count nothing but would lag the pool by the thawing period.
--
-- Horizon: `DelegatedTokensWithdrawn` is the exit. Whether the Horizon pool should also shrink at
-- `TokensUndelegated` is the one modelling choice here that the gateway comparison arbitrates rather
-- than reasoning - stated plainly because it is the likeliest thing to be wrong.
-- Delegation. Two corrections live here, both from reading the subgraph's mappings rather than
-- reasoning about the protocol.
--
-- **The exit event.** A Horizon delegation leaves the pool at `TokensUndelegated`, which burns the
-- shares; `DelegatedTokensWithdrawn` only releases tokens that already left and are done thawing.
-- Subtracting at withdrawal counts a thawing stake as still delegated, which is what left
-- `totalDelegatedTokens` 16.3% high. The legacy era has the same shape with different names:
-- `StakeDelegatedLocked` is the exit, `StakeDelegatedWithdrawn` the release.
--
-- **Shares, not tokens.** `activeDelegatorCount` tracks `delegatedStake.shareAmount` reaching zero
-- (`staking.ts:249`, `horizonStaking.ts:510`), never the token balance. Tokens accrue rewards while
-- shares do not, so the two diverge and netting tokens reports the wrong people as active.
delegation AS (
  SELECT delegator, sp, SUM(tok) AS net_tokens, SUM(sh) AS net_shares FROM (
    SELECT delegator, indexer AS sp,
           CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh
      FROM staking_legacy__stake_delegated
    UNION ALL
    SELECT delegator, indexer,
          -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)
      FROM staking_legacy__stake_delegated_locked
    UNION ALL
    SELECT delegator, "serviceProvider",
           CAST(tokens AS HUGEINT),         CAST(shares AS HUGEINT)
      FROM staking__tokens_delegated
    UNION ALL
    SELECT delegator, "serviceProvider",
          -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)
      FROM staking__tokens_undelegated
  ) GROUP BY 1, 2
),
delegated AS (
  SELECT (SELECT SUM(net_tokens) FROM delegation) AS total,
         (SELECT COUNT(DISTINCT delegator) FROM delegation) AS n_all,
         (SELECT COUNT(DISTINCT delegator) FROM delegation WHERE net_shares > 0) AS n_positive
),
-- Curators, per the network subgraph's own rule (#649). `curatorCount` is distinct addresses ever
-- passed to `createOrLoadCurator`, which fires from Curation `Signalled`/`Burned` *and* from the GNS
-- name-signal handlers. Counting Curation alone gave 50 against the gateway's 1,819, because on L2
-- most signal is routed through GNS and the Curation-level `curator` is then the GNS contract itself.
--
-- `activeCuratorCount` is a different question and is not a distinct count: the subgraph increments
-- it only when a curator's `activeCombinedSignalCount` reaches 1, so it means "curators holding at
-- least one live position". A position is (curator, deployment) for curation signal and
-- (curator, subgraphID) for name signal, netted separately and only then folded together.
curator_positions AS (
  SELECT curator, position, SUM(sig) AS net FROM (
    SELECT curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR) AS position,
           CAST(signal AS HUGEINT) AS sig FROM curation__signalled
    UNION ALL
    SELECT curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR),
          -CAST(signal AS HUGEINT)      FROM curation__burned
    UNION ALL
    SELECT curator, 'n:' || CAST("subgraphID" AS VARCHAR),
           CAST("nSignalCreated" AS HUGEINT) FROM gns__signal_minted
    UNION ALL
    SELECT curator, 'n:' || CAST("subgraphID" AS VARCHAR),
          -CAST("nSignalBurnt" AS HUGEINT)   FROM gns__signal_burned
    -- `GRTWithdrawn` is deliberately absent. It is one of the eight handlers that create a Curator
    -- in the subgraph, but it never fired on L2 - the event belongs to the L1 migration path - so
    -- nuthatch created no table for it, and a view referencing a table that does not exist fails to
    -- load *in its entirety*, taking the other thirteen fields with it. See issue #663.
  ) GROUP BY 1, 2
),
signalled AS (
  SELECT (SELECT SUM(t) FROM (
            SELECT CAST(tokens AS HUGEINT) AS t FROM curation__signalled
            UNION ALL SELECT -CAST(tokens AS HUGEINT) FROM curation__burned
          )) AS total,
         (SELECT COUNT(DISTINCT curator) FROM curator_positions) AS n_all,
         (SELECT COUNT(DISTINCT curator) FROM curator_positions WHERE net > 0) AS n_positive
),
allocated AS (
  SELECT SUM(allocated_tokens) AS total FROM lodestar_allocations WHERE status = 'Active'
),
subgraphs AS (
  SELECT COUNT(DISTINCT "subgraphID") AS n_all,
         COUNT(DISTINCT "subgraphID") FILTER (
           WHERE "subgraphID" NOT IN (SELECT "subgraphID" FROM gns__subgraph_deprecated)
         ) AS n_active
  FROM gns__subgraph_published
),
-- The newest pinned read. `reverted` would mean the call failed at that block, which is a fact about
-- chain state rather than a zero, so it is excluded rather than counted as none.
supply AS (
  SELECT CAST(result AS VARCHAR) AS raw, block_number
  FROM grt_total_supply WHERE reverted = false
  ORDER BY block_number DESC LIMIT 1
)
SELECT (SELECT total      FROM staked)     AS total_tokens_staked,
       (SELECT total      FROM delegated)  AS total_delegated_tokens,
       (SELECT total      FROM signalled)  AS total_tokens_signalled,
       (SELECT total      FROM allocated)  AS total_tokens_allocated,
       (SELECT raw        FROM supply)     AS total_supply_raw,
       (SELECT block_number FROM supply)   AS total_supply_at_block,
       (SELECT n_all      FROM staked)     AS indexer_count,
       (SELECT n_positive FROM staked)     AS staked_indexers_count,
       (SELECT n_all      FROM delegated)  AS delegator_count,
       (SELECT n_positive FROM delegated)  AS active_delegator_count,
       (SELECT n_all      FROM signalled)  AS curator_count,
       (SELECT n_positive FROM signalled)  AS active_curator_count,
       (SELECT n_all      FROM subgraphs)  AS subgraph_count,
       (SELECT n_active   FROM subgraphs)  AS active_subgraph_count,
       (SELECT MAX(epoch) FROM epoch_boundaries) AS current_epoch;
