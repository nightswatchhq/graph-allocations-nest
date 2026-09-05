-- Lodestar's `Indexer`, `DelegatedStake`, `Curator` and `Provision` shapes, folded from events
-- (nuthatch#1160, the surfaces #1078 left: `api/indexers`, `api/indexer/[address]`,
-- `api/indexer-stake-history`, `api/rewards-history`, `api/curators`, `api/provisions`,
-- `api/portfolio`, `api/apr-provenance`, `lib/refresh.ts`, the indexer OpenGraph image).
--
-- Every modelling choice here is the one `80-lodestar-network.sql` already made and measured against
-- the gateway, applied per entity instead of summed: stake nets deposits, withdrawals and legacy
-- slashing; a delegation leaves the pool at the *exit* event (`StakeDelegatedLocked` before Horizon,
-- `TokensUndelegated` after), not at withdrawal; "active" is shares, not tokens. Where this view has
-- to say something the network view did not, the paragraph above the CTE says what and why, and the
-- parity run against the subgraph arbitrates rather than the reasoning.
--
-- Units: `*_tokens` and `*_shares` are wei as HUGEINT; cuts are parts per million as the contracts
-- emit them; addresses are lower-cased; `id` follows the subgraph (the address, or `delegator-indexer`).

-- ---------------------------------------------------------------------------------------------
-- Per-indexer stake, delegation pool, cuts, rewards, fees, registry and provisions.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_indexers AS
WITH
-- Own stake. Horizon renamed the events at block ~408,847,369; both eras are one history. Slashing
-- is legacy only - `ProvisionSlashed` has never fired (network view, measured) - and `tokens` is the
-- whole amount removed; `reward` is the informer's cut of that same sum, so it is not subtracted.
stake_events AS (
  SELECT LOWER(indexer) AS sp,            CAST(tokens AS HUGEINT) AS t, block_timestamp AS ts, block_number AS bn FROM staking_legacy__stake_deposited
  UNION ALL SELECT LOWER(indexer),          -CAST(tokens AS HUGEINT), block_timestamp, block_number FROM staking_legacy__stake_withdrawn
  UNION ALL SELECT LOWER(indexer),          -CAST(tokens AS HUGEINT), block_timestamp, block_number FROM staking_legacy__stake_slashed
  UNION ALL SELECT LOWER("serviceProvider"), CAST(tokens AS HUGEINT), block_timestamp, block_number FROM staking__horizon_stake_deposited
  UNION ALL SELECT LOWER("serviceProvider"),-CAST(tokens AS HUGEINT), block_timestamp, block_number FROM staking__horizon_stake_withdrawn
  UNION ALL SELECT LOWER("serviceProvider"),-CAST(tokens AS HUGEINT), block_timestamp, block_number FROM staking__provision_slashed
),
stake AS (
  SELECT sp, SUM(t) AS staked_tokens,
         MIN(ts) FILTER (WHERE t > 0) AS created_at,
         MIN(bn) FILTER (WHERE t > 0) AS created_at_block
  FROM stake_events GROUP BY 1
),
-- Locked (thawing) own stake. Both `StakeLocked` and `HorizonStakeLocked` carry the *total* locked
-- amount and its release time, not a delta, so the newest event is the state - unless a withdrawal
-- came after it, which empties the lock. `thawing_period` on Horizon is per provision; this is the
-- legacy-shaped `lockedTokens` / `lockedUntil` the indexer pages show.
lock_events AS (
  SELECT LOWER(indexer) AS sp, CAST(tokens AS HUGEINT) AS tokens, CAST("until" AS HUGEINT) AS until_block, block_number AS bn, log_index AS li FROM staking_legacy__stake_locked
  UNION ALL SELECT LOWER("serviceProvider"), CAST(tokens AS HUGEINT), CAST("until" AS HUGEINT), block_number, log_index FROM staking__horizon_stake_locked
),
withdraw_events AS (
  SELECT LOWER(indexer) AS sp, block_number AS bn, log_index AS li FROM staking_legacy__stake_withdrawn
  UNION ALL SELECT LOWER("serviceProvider"), block_number, log_index FROM staking__horizon_stake_withdrawn
),
locked AS (
  SELECT l.sp,
         CASE WHEN w.bn IS NULL OR (l.bn, l.li) > (w.bn, w.li) THEN l.tokens ELSE 0 END AS locked_tokens,
         CASE WHEN w.bn IS NULL OR (l.bn, l.li) > (w.bn, w.li) THEN l.until_block ELSE NULL END AS locked_until
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY sp ORDER BY bn DESC, li DESC) AS rn FROM lock_events) l
  LEFT JOIN (SELECT sp, MAX(bn) AS bn, MAX(li) AS li FROM withdraw_events GROUP BY 1) w ON w.sp = l.sp
  WHERE l.rn = 1
),
-- Delegation, per (delegator, indexer), exit at the exit event. Identical to the network view's
-- fold, kept per pair so `lodestar_delegator_stakes` below and the pool here cannot disagree.
delegation AS (
  SELECT delegator, sp, SUM(tok) AS net_tokens, SUM(sh) AS net_shares FROM (
    SELECT LOWER(delegator) AS delegator, LOWER(indexer) AS sp,            CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(delegator), LOWER(indexer),                     -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)      FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),            CAST(tokens AS HUGEINT),         CAST(shares AS HUGEINT)      FROM staking__tokens_delegated
    UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),           -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)      FROM staking__tokens_undelegated
  ) GROUP BY 1, 2
),
-- Rewards that land in the pool without a delegation event. The subgraph's `delegatedTokens` grows
-- when the delegators' share of rewards is added to the pool, and tokens leave the pool *with* those
-- rewards, so a pool netted from delegation events alone goes negative on any old indexer (measured:
-- -68k GRT against 1.18M shares on the first real-data run). Horizon states the addition:
-- `TokensToDelegationPoolAdded`. Legacy states the query-fee half (`RebateCollected.delegationRewards`,
-- `RebateClaimed.delegationFees`) but the indexing-reward half was split inside the staking contract
-- and never emitted, so it is *computed*: each pre-Horizon `RewardsAssigned.amount` times one minus
-- the `indexingRewardCut` in force at that block, per `Staking._collectDelegationIndexingRewards`.
-- The cut in force is the newest `DelegationParametersUpdated` at or before the event (an ASOF join
-- on block-then-log order); a first stake sets the cuts to 100% and emits that event, so every
-- indexer has one before its first reward. The contract also skips the addition when the pool holds
-- no tokens, which the cut alone does not know; at a 100% cut the share is zero anyway, and the
-- parity run arbitrates the rest. Bounded by the first `HorizonStakeDeposited` block because after
-- the upgrade the same split is emitted as `TokensToDelegationPoolAdded` and would double count.
-- `DelegationSlashed` removes from the pool and has never fired; it is folded anyway.
horizon_start AS (SELECT MIN(block_number) AS bn FROM staking__horizon_stake_deposited),
legacy_reward_share AS (
  -- `//`, not `/`: DuckDB's `/` is floating-point division and would turn wei into a DOUBLE.
  SELECT r.sp, SUM(r.amount * (1000000 - c.cut) // 1000000) AS t
  FROM (SELECT LOWER(indexer) AS sp, CAST(amount AS HUGEINT) AS amount,
               block_number * 100000 + log_index AS k, block_number AS bn
        FROM rewards__rewards_assigned) r
  ASOF JOIN (SELECT LOWER(indexer) AS sp, CAST("indexingRewardCut" AS HUGEINT) AS cut,
                    block_number * 100000 + log_index AS k
             FROM staking_legacy__delegation_parameters_updated) c
    ON r.sp = c.sp AND r.k >= c.k
  WHERE r.bn < COALESCE((SELECT bn FROM horizon_start), 9223372036854775807)
  GROUP BY 1
),
-- The second silent addition, and the last: a *legacy* allocation closed after the upgrade goes
-- through the compatibility path, which adds the delegators' share of its rewards to the pool with
-- no `TokensToDelegationPoolAdded`, using the legacy `indexingRewardCut`. The reward itself is
-- emitted as `HorizonRewardsAssigned` on a legacy allocation id. Measured on two indexers against
-- `getDelegationPool` at the current block: 20,791 GRT of a 20,791 gap on one; 9,331 of 18,101 on the
-- other, whose remaining 8,770 is its `tokensThawing` (8,769), which the contract keeps in
-- `pool.tokens` and the subgraph does not. With this, `delegated_tokens + delegated_thawing_tokens`
-- equals the contract's `pool.tokens` and `delegated_tokens` equals the subgraph's `delegatedTokens`.
legacy_path_share AS (
  SELECT h.sp, SUM(h.amount * (1000000 - c.cut) // 1000000) AS t
  FROM (SELECT LOWER(indexer) AS sp, LOWER("allocationID") AS a, CAST(amount AS HUGEINT) AS amount,
               block_number * 100000 + log_index AS k
        FROM rewards__horizon_rewards_assigned) h
  ASOF JOIN (SELECT LOWER(indexer) AS sp, CAST("indexingRewardCut" AS HUGEINT) AS cut,
                    block_number * 100000 + log_index AS k
             FROM staking_legacy__delegation_parameters_updated) c
    ON h.sp = c.sp AND h.k >= c.k
  WHERE h.a IN (SELECT LOWER("allocationID") FROM staking_legacy__allocation_created)
  GROUP BY 1
),
pool_adjust AS (
  SELECT sp, SUM(t) AS pool_rewards_added FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t FROM staking__tokens_to_delegation_pool_added
    UNION ALL SELECT sp, t FROM legacy_path_share
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT) FROM staking__delegation_slashed
    UNION ALL SELECT LOWER(indexer),  CAST("delegationRewards" AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT LOWER(indexer),  CAST("delegationFees" AS HUGEINT)    FROM staking_legacy__rebate_claimed
    UNION ALL SELECT sp, t FROM legacy_reward_share
  ) GROUP BY 1
),
pool AS (
  SELECT sp,
         SUM(net_tokens)                                     AS delegated_net,
         SUM(net_shares)                                     AS delegator_shares,
         COUNT(DISTINCT delegator) FILTER (WHERE net_shares > 0) AS delegator_count
  FROM delegation GROUP BY 1
),
-- Undelegated and not yet withdrawn: the subgraph's `delegatedThawingTokens`, which is a Horizon
-- quantity (`pool.tokensThawing`) and is exit minus release over Horizon events only. Measured against
-- `getDelegationPool` on two indexers: 8,769 and 0 GRT, both exact. Legacy undelegations that were
-- never withdrawn are not thawing - they sit in the delegator's `tokensLocked` forever, 1.2M GRT on
-- one indexer - so they are carried in their own column and kept out of this one.
thawing AS (
  SELECT sp, GREATEST(SUM(t), 0) AS delegated_thawing_tokens, GREATEST(SUM(l), 0) AS legacy_locked_unwithdrawn FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t, CAST(0 AS HUGEINT) AS l FROM staking__tokens_undelegated
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT), 0 FROM staking__delegated_tokens_withdrawn
    UNION ALL SELECT LOWER(indexer), 0,  CAST(tokens AS HUGEINT) FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER(indexer), 0, -CAST(tokens AS HUGEINT) FROM staking__stake_delegated_withdrawn
  ) GROUP BY 1
),
-- Active allocations. The Horizon ones come from `lodestar_allocations` so the two surfaces share one
-- definition. A legacy allocation still open today is one that was created before the upgrade and
-- neither closed under either legacy `AllocationClosed` overload nor migrated into the subgraph
-- service (a migrated one is the service's to close, and is counted there).
legacy_open AS (
  SELECT LOWER(indexer) AS sp, CAST(tokens AS HUGEINT) AS tokens
  FROM staking_legacy__allocation_created c
  WHERE c."allocationID" NOT IN (SELECT "allocationID" FROM staking_legacy__allocation_closed_7203)
    AND c."allocationID" NOT IN (SELECT "allocationID" FROM staking_legacy__allocation_closed_f672)
    AND c."allocationID" NOT IN (SELECT "allocationId" FROM subgraph_service__legacy_allocation_migrated)
),
allocated AS (
  SELECT sp, SUM(tokens) AS allocated_tokens, COUNT(*) AS allocation_count FROM (
    SELECT LOWER(indexer) AS sp, allocated_tokens AS tokens FROM lodestar_allocations WHERE status = 'Active'
    UNION ALL SELECT sp, tokens FROM legacy_open
  ) GROUP BY 1
),
-- Delegation cuts, parts per million, newest of either era wins. Horizon sets them per payment type:
-- 0 = QueryFee, 1 = IndexingFee, 2 = IndexingRewards (`IGraphPayments.PaymentTypes`), and per
-- verifier; the subgraph reports the subgraph service's, and that is the only verifier that has set
-- any, so no filter is applied and the parity run will say if that stops being true.
cut_events AS (
  SELECT LOWER(indexer) AS sp, 'indexing' AS kind, CAST("indexingRewardCut" AS HUGEINT) AS cut, block_number AS bn, log_index AS li, block_timestamp AS ts FROM staking_legacy__delegation_parameters_updated
  UNION ALL SELECT LOWER(indexer), 'query',    CAST("queryFeeCut" AS HUGEINT),       block_number, log_index, block_timestamp FROM staking_legacy__delegation_parameters_updated
  UNION ALL SELECT LOWER("serviceProvider"), CASE WHEN CAST("paymentType" AS INTEGER) = 2 THEN 'indexing' WHEN CAST("paymentType" AS INTEGER) = 0 THEN 'query' ELSE 'other' END,
                   CAST("feeCut" AS HUGEINT), block_number, log_index, block_timestamp FROM staking__delegation_fee_cut_set
),
cuts AS (
  SELECT sp,
         MAX(cut) FILTER (WHERE kind = 'indexing' AND rn = 1) AS indexing_reward_cut,
         MAX(cut) FILTER (WHERE kind = 'query'    AND rn = 1) AS query_fee_cut,
         MAX(ts)                                              AS last_delegation_parameter_update
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY sp, kind ORDER BY bn DESC, li DESC) AS rn FROM cut_events)
  GROUP BY 1
),
-- Indexing rewards assigned, both eras; the subgraph's `rewardsEarned` is the gross figure before the
-- delegators' share, which is what `RewardsAssigned.amount` is.
rewards AS (
  SELECT sp, SUM(t) AS rewards_earned FROM (
    SELECT LOWER(indexer) AS sp, CAST(amount AS HUGEINT) AS t FROM rewards__rewards_assigned
    UNION ALL SELECT LOWER(indexer), CAST(amount AS HUGEINT) FROM rewards__horizon_rewards_assigned
  ) GROUP BY 1
),
-- Query fees. Three mechanisms across the protocol's life: `AllocationCollected` (oldest, gross of
-- curation), `RebateCollected.queryFees` (the rebate era), and the subgraph service's
-- `QueryFeesCollected.tokensCollected`. Summed; if the subgraph's `queryFeesCollected` turns out to
-- net curation fees off the first, the parity run will show a constant offset on old indexers.
fees AS (
  SELECT sp, SUM(t) AS query_fees_collected FROM (
    SELECT LOWER(indexer) AS sp, CAST(tokens AS HUGEINT) - CAST("curationFees" AS HUGEINT) AS t FROM staking_legacy__allocation_collected
    UNION ALL SELECT LOWER(indexer), CAST("queryFees" AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT LOWER("serviceProvider"), CAST("tokensCollected" AS HUGEINT) FROM subgraph_service__query_fees_collected
  ) GROUP BY 1
),
-- Service registry: the newest of register / unregister per indexer is the state.
registry AS (
  SELECT sp, CASE WHEN kind = 'reg' THEN url ELSE NULL END AS url,
             CASE WHEN kind = 'reg' THEN geohash ELSE NULL END AS geohash
  FROM (
    SELECT LOWER(indexer) AS sp, 'reg' AS kind, url, geohash, block_number AS bn, log_index AS li,
           ROW_NUMBER() OVER (PARTITION BY LOWER(indexer) ORDER BY block_number DESC, log_index DESC) AS rn
    FROM (
      SELECT indexer, url, geohash, block_number, log_index FROM service_registry__service_registered
      UNION ALL SELECT indexer, NULL, NULL, block_number, log_index FROM service_registry__service_unregistered
    )
  ) WHERE rn = 1
),
-- Provisioned stake across every verifier; `lodestar_provisions` below has it per verifier.
provisioned AS (
  SELECT sp, SUM(t) AS provisioned_tokens FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t FROM staking__provision_created
    UNION ALL SELECT LOWER("serviceProvider"),  CAST(tokens AS HUGEINT) FROM staking__provision_increased
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT) FROM staking__tokens_deprovisioned
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT) FROM staking__provision_slashed
  ) GROUP BY 1
)
SELECT s.sp                                                     AS id,
       s.staked_tokens,
       COALESCE(l.locked_tokens, 0)                             AS locked_tokens,
       l.locked_until,
       COALESCE(p.delegated_net, 0) + COALESCE(pa.pool_rewards_added, 0) AS delegated_tokens,
       COALESCE(p.delegated_net, 0)                             AS delegated_net,
       COALESCE(pa.pool_rewards_added, 0)                       AS delegated_pool_rewards,
       COALESCE(p.delegator_shares, 0)                          AS delegator_shares,
       COALESCE(p.delegator_count, 0)                           AS delegator_count,
       COALESCE(th.delegated_thawing_tokens, 0)                 AS delegated_thawing_tokens,
       COALESCE(th.legacy_locked_unwithdrawn, 0)                AS legacy_locked_unwithdrawn,
       COALESCE(a.allocated_tokens, 0)                          AS allocated_tokens,
       COALESCE(a.allocation_count, 0)                          AS allocation_count,
       c.indexing_reward_cut,
       c.query_fee_cut,
       c.last_delegation_parameter_update,
       COALESCE(r.rewards_earned, 0)                            AS rewards_earned,
       COALESCE(f.query_fees_collected, 0)                      AS query_fees_collected,
       COALESCE(pr.provisioned_tokens, 0)                       AS provisioned_tokens,
       g.url,
       g.geohash,
       s.created_at,
       s.created_at_block
FROM stake s
LEFT JOIN locked      l  ON l.sp  = s.sp
LEFT JOIN pool        p  ON p.sp  = s.sp
LEFT JOIN pool_adjust pa ON pa.sp = s.sp
LEFT JOIN thawing     th ON th.sp = s.sp
LEFT JOIN allocated   a  ON a.sp  = s.sp
LEFT JOIN cuts        c  ON c.sp  = s.sp
LEFT JOIN rewards     r  ON r.sp  = s.sp
LEFT JOIN fees        f  ON f.sp  = s.sp
LEFT JOIN registry    g  ON g.sp  = s.sp
LEFT JOIN provisioned pr ON pr.sp = s.sp;

-- ---------------------------------------------------------------------------------------------
-- Per (delegator, indexer): the subgraph's `DelegatedStake`. Shares are exact; the token value of a
-- position is its share of the pool, `shares * pool_tokens / pool_shares`, which is how the
-- contracts value it too. Rows with zero shares are kept (a closed position is history the
-- portfolio page shows) and flagged.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_delegator_stakes AS
WITH events AS (
  SELECT LOWER(delegator) AS delegator, LOWER(indexer) AS indexer,  CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh, block_timestamp AS ts, 'in'  AS dir FROM staking_legacy__stake_delegated
  UNION ALL SELECT LOWER(delegator), LOWER(indexer),               -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT),      block_timestamp, 'out' FROM staking_legacy__stake_delegated_locked
  UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),      CAST(tokens AS HUGEINT),         CAST(shares AS HUGEINT),      block_timestamp, 'in'  FROM staking__tokens_delegated
  UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),     -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT),      block_timestamp, 'out' FROM staking__tokens_undelegated
),
pairs AS (
  SELECT delegator, indexer,
         SUM(sh)                                   AS share_amount,
         SUM(tok) FILTER (WHERE dir = 'in')        AS total_delegated_tokens,
         -SUM(tok) FILTER (WHERE dir = 'out')      AS total_undelegated_tokens,
         MIN(ts)                                   AS created_at,
         MAX(ts) FILTER (WHERE dir = 'out')        AS last_undelegated_at
  FROM events GROUP BY 1, 2
)
SELECT p.delegator || '-' || p.indexer                          AS id,
       p.delegator,
       p.indexer,
       p.share_amount,
       CASE WHEN i.delegator_shares > 0
            THEN CAST(p.share_amount * i.delegated_tokens / i.delegator_shares AS HUGEINT)
            ELSE 0 END                                          AS staked_tokens,
       COALESCE(p.total_delegated_tokens, 0)                   AS total_delegated_tokens,
       COALESCE(p.total_undelegated_tokens, 0)                 AS total_undelegated_tokens,
       p.share_amount > 0                                       AS active,
       p.created_at,
       p.last_undelegated_at
FROM pairs p
LEFT JOIN lodestar_indexers i ON i.id = p.indexer;

-- ---------------------------------------------------------------------------------------------
-- Curators, per the network subgraph's own rule (network view, #649): a curator is an address that
-- ever signalled through Curation *or* GNS, positions are netted per (curator, deployment) and per
-- (curator, subgraph) separately, and "active" is holding at least one position with signal left.
-- On L2 most signal is routed through GNS and the Curation-level curator is then the GNS contract
-- itself; that row is kept and flagged `is_gns`, so `api/curators` can drop it the way the subgraph's
-- list effectively does, without this view deciding for it.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_curators AS
WITH positions AS (
  SELECT curator, position, SUM(sig) AS net_signal, SUM(tin) AS tokens_in, SUM(tout) AS tokens_out FROM (
    SELECT LOWER(curator) AS curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR) AS position,  CAST(signal AS HUGEINT) AS sig, CAST(tokens AS HUGEINT) AS tin, CAST(0 AS HUGEINT) AS tout FROM curation__signalled
    UNION ALL SELECT LOWER(curator), 'v:' || CAST("subgraphDeploymentID" AS VARCHAR), -CAST(signal AS HUGEINT), 0, CAST(tokens AS HUGEINT) FROM curation__burned
    UNION ALL SELECT LOWER(curator), 'n:' || CAST("subgraphID" AS VARCHAR),  CAST("nSignalCreated" AS HUGEINT), CAST("tokensDeposited" AS HUGEINT), 0 FROM gns__signal_minted
    UNION ALL SELECT LOWER(curator), 'n:' || CAST("subgraphID" AS VARCHAR), -CAST("nSignalBurnt" AS HUGEINT), 0, CAST("tokensReceived" AS HUGEINT) FROM gns__signal_burned
  ) GROUP BY 1, 2
)
SELECT curator                                            AS id,
       SUM(tokens_in)                                     AS total_signalled_tokens,
       SUM(tokens_out)                                    AS total_unsignalled_tokens,
       COUNT(*)                                           AS signal_count,
       COUNT(*) FILTER (WHERE net_signal > 0)             AS active_signal_count,
       curator = '0xec9a7fb6cbc2e41926127929c2dce6e9c5d33bec' AS is_gns
FROM positions GROUP BY 1;

-- ---------------------------------------------------------------------------------------------
-- Provisions, per (indexer, verifier): the subgraph's `Provision`. Created plus increased, less
-- deprovisioned and slashed; thawing is what has been thawed and not yet deprovisioned. Allocation
-- and reward figures only mean anything for the subgraph service's provision, and are joined for
-- that verifier only (the address is the nest's `subgraph_service` contract).
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_provisions AS
WITH created AS (
  SELECT LOWER("serviceProvider") AS indexer, LOWER(verifier) AS verifier,
         CAST("maxVerifierCut" AS HUGEINT) AS max_verifier_cut,
         CAST("thawingPeriod" AS HUGEINT)  AS thawing_period,
         block_timestamp AS created_at, block_number AS created_at_block,
         ROW_NUMBER() OVER (PARTITION BY LOWER("serviceProvider"), LOWER(verifier) ORDER BY block_number DESC, log_index DESC) AS rn
  FROM staking__provision_created
),
flows AS (
  SELECT indexer, verifier, SUM(t) AS tokens_provisioned, GREATEST(SUM(th), 0) AS tokens_thawing FROM (
    SELECT LOWER("serviceProvider") AS indexer, LOWER(verifier) AS verifier,  CAST(tokens AS HUGEINT) AS t, CAST(0 AS HUGEINT) AS th FROM staking__provision_created
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier),  CAST(tokens AS HUGEINT), 0 FROM staking__provision_increased
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), -CAST(tokens AS HUGEINT), -CAST(tokens AS HUGEINT) FROM staking__tokens_deprovisioned
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), -CAST(tokens AS HUGEINT), 0 FROM staking__provision_slashed
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), 0,  CAST(tokens AS HUGEINT) FROM staking__provision_thawed
  ) GROUP BY 1, 2
),
service_allocs AS (
  SELECT LOWER(indexer) AS indexer,
         SUM(allocated_tokens) FILTER (WHERE status = 'Active') AS tokens_allocated,
         COUNT(*) FILTER (WHERE status = 'Active')             AS allocation_count,
         SUM(indexing_rewards)                                  AS rewards_earned,
         SUM(query_fees_collected)                              AS query_fees_collected
  FROM lodestar_allocations GROUP BY 1
)
SELECT f.indexer || '-' || f.verifier                 AS id,
       f.indexer,
       f.verifier                                     AS data_service,
       f.tokens_provisioned,
       f.tokens_thawing,
       c.max_verifier_cut,
       c.thawing_period,
       c.created_at,
       c.created_at_block,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.tokens_allocated, 0) END      AS tokens_allocated,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.allocation_count, 0) END      AS allocation_count,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.rewards_earned, 0) END        AS rewards_earned,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.query_fees_collected, 0) END  AS query_fees_collected
FROM flows f
LEFT JOIN (SELECT * FROM created WHERE rn = 1) c ON c.indexer = f.indexer AND c.verifier = f.verifier
LEFT JOIN service_allocs sa ON sa.indexer = f.indexer;
