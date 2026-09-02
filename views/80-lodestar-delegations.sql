-- Lodestar's delegation_events shape, from Horizon and pre-Horizon staking events.
--
-- Maps onto `lodestar/src/lib/ingest/delegations.ts` and the inline UNION already used by
-- `/api/delegation-events`. event_type uses the community subgraph's vocabulary
-- (delegation / undelegation / withdrawal) so a switch does not rewrite the consumer.
--
-- Horizon renamed every staking event. The four `staking__*` tables are the current names;
-- `staking_legacy__stake_delegated` and `stake_delegated_locked` are the same proxy before
-- the upgrade. Drop the legacy pair and 366M blocks vanish. StakeDelegatedLocked is an
-- undelegation (tokens locked, then withdrawn), not a withdrawal; withdrawal is the later
-- DelegatedTokensWithdrawn / StakeDelegatedWithdrawn pair.
--
-- `id` is tx_hash-log_index, stable and reproducible. `tokens` is wei as HUGEINT, matching
-- the escrow view; the cron currently divides by 1e18 in process.
CREATE VIEW lodestar_delegations AS
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR) AS id,
       'delegation'                 AS event_type,
       LOWER(delegator)             AS delegator,
       LOWER("serviceProvider")     AS indexer,
       CAST(tokens AS HUGEINT)      AS tokens,
       block_timestamp              AS timestamp,
       block_number
FROM staking__tokens_delegated
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR),
       'undelegation',
       LOWER(delegator),
       LOWER("serviceProvider"),
       CAST(tokens AS HUGEINT),
       block_timestamp,
       block_number
FROM staking__tokens_undelegated
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR),
       'withdrawal',
       LOWER(delegator),
       LOWER("serviceProvider"),
       CAST(tokens AS HUGEINT),
       block_timestamp,
       block_number
FROM staking__delegated_tokens_withdrawn
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR),
       'withdrawal',
       LOWER(delegator),
       LOWER(indexer),
       CAST(tokens AS HUGEINT),
       block_timestamp,
       block_number
FROM staking__stake_delegated_withdrawn
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR),
       'delegation',
       LOWER(delegator),
       LOWER(indexer),
       CAST(tokens AS HUGEINT),
       block_timestamp,
       block_number
FROM staking_legacy__stake_delegated
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR),
       'undelegation',
       LOWER(delegator),
       LOWER(indexer),
       CAST(tokens AS HUGEINT),
       block_timestamp,
       block_number
FROM staking_legacy__stake_delegated_locked;
