-- The governance parameters and totals Lodestar's network page shows beside `lodestar_network`
-- (nuthatch#1160), from the four pinned samples in `nuthatch.toml` and the epoch manager's events.
--
-- One row. Each sample is the newest non-reverted read, decoded the way `lodestar_network` decodes
-- `total_supply`: the last 32 hex characters of the raw return word folded base-16 into a HUGEINT.
-- `epoch_length` is not sampled because `epochs__epoch_length_update` carries every change to the
-- block, so the newest event is the state. Three legacy parameters the subgraph still reports -
-- `thawingPeriod`, `maxAllocationEpochs`, `delegationTaxPercentage` - have no getter on the Horizon
-- proxy and no column here: a consumer that needs them is showing a number that stopped meaning
-- anything at the upgrade, and this view declines to invent one.
--
-- The two tax totals are for `api/grt-flow`, whose `minted`/`burned` on the gateway path are the
-- subgraph's all-mints and all-burns; `lodestar_network` carries the bridge halves and the issuance
-- half, and these are the burn halves that remain: the protocol's cut of query fees (1%, burned)
-- and the curation tax (1% of every signal, burned).
CREATE VIEW lodestar_network_params AS
WITH dec AS (
  -- newest non-reverted sample per parameter, decoded
  SELECT name, value, block_number FROM (
    SELECT 'delegation_ratio' AS name,
           list_reduce([CAST(strpos('0123456789abcdef', c) - 1 AS HUGEINT)
                        FOR c IN string_split(substr(lower(CAST(result AS VARCHAR)), -32), '')],
                       lambda acc, d: acc * 16 + d) AS value,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM delegation_ratio WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, value, block_number FROM (
    SELECT 'curation_tax_percentage' AS name,
           list_reduce([CAST(strpos('0123456789abcdef', c) - 1 AS HUGEINT)
                        FOR c IN string_split(substr(lower(CAST(result AS VARCHAR)), -32), '')],
                       lambda acc, d: acc * 16 + d) AS value,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM curation_tax_percentage WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, value, block_number FROM (
    SELECT 'protocol_payment_cut' AS name,
           list_reduce([CAST(strpos('0123456789abcdef', c) - 1 AS HUGEINT)
                        FOR c IN string_split(substr(lower(CAST(result AS VARCHAR)), -32), '')],
                       lambda acc, d: acc * 16 + d) AS value,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM protocol_payment_cut WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, value, block_number FROM (
    SELECT 'max_thawing_period' AS name,
           list_reduce([CAST(strpos('0123456789abcdef', c) - 1 AS HUGEINT)
                        FOR c IN string_split(substr(lower(CAST(result AS VARCHAR)), -32), '')],
                       lambda acc, d: acc * 16 + d) AS value,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM max_thawing_period WHERE reverted = false
  ) WHERE rn = 1
),
epoch_len AS (
  SELECT CAST("epochLength" AS HUGEINT) AS epoch_length, CAST(epoch AS HUGEINT) AS last_length_update_epoch,
         block_number AS last_length_update_block
  FROM epochs__epoch_length_update ORDER BY block_number DESC, log_index DESC LIMIT 1
),
taxes AS (
  SELECT (SELECT SUM(CAST("curationTax" AS HUGEINT)) FROM curation__signalled) AS total_curation_tax,
         -- The protocol's cut of every query fee collected: `tokensCollected // 100` is how
         -- `lodestar_epochs` already accounts for it, so the two agree by construction.
         (SELECT SUM(CAST("tokensCollected" AS HUGEINT) // 100) FROM subgraph_service__query_fees_collected) AS total_protocol_tax
)
SELECT (SELECT value        FROM dec WHERE name = 'delegation_ratio')        AS delegation_ratio,
       (SELECT block_number FROM dec WHERE name = 'delegation_ratio')        AS delegation_ratio_at_block,
       (SELECT value        FROM dec WHERE name = 'curation_tax_percentage') AS curation_tax_percentage,
       (SELECT value        FROM dec WHERE name = 'protocol_payment_cut')    AS protocol_payment_cut,
       (SELECT value        FROM dec WHERE name = 'max_thawing_period')      AS max_thawing_period_seconds,
       e.epoch_length,
       e.last_length_update_epoch,
       e.last_length_update_block,
       t.total_curation_tax,
       t.total_protocol_tax
FROM epoch_len e, taxes t;
