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
WITH samples AS (
  -- newest non-reverted sample per parameter: the last 32 hex characters of its return word
  SELECT name, h, block_number FROM (
    SELECT 'delegation_ratio' AS name, right(lower(CAST(result AS VARCHAR)), 32) AS h,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM delegation_ratio WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, h, block_number FROM (
    SELECT 'curation_tax_percentage' AS name, right(lower(CAST(result AS VARCHAR)), 32) AS h,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM curation_tax_percentage WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, h, block_number FROM (
    SELECT 'protocol_payment_cut' AS name, right(lower(CAST(result AS VARCHAR)), 32) AS h,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM protocol_payment_cut WHERE reverted = false
  ) WHERE rn = 1
  UNION ALL
  SELECT name, h, block_number FROM (
    SELECT 'max_thawing_period' AS name, right(lower(CAST(result AS VARCHAR)), 32) AS h,
           block_number, ROW_NUMBER() OVER (ORDER BY block_number DESC) AS rn
    FROM max_thawing_period WHERE reverted = false
  ) WHERE rn = 1
),
dec AS (
  -- The 32 hex characters folded base-16 into a HUGEINT: the sum `list_reduce(..., acc * 16 + d)`
  -- computes, written out, so an engine without DuckDB's list lambdas reads the same number.
  SELECT name,
         CAST(strpos('0123456789abcdef', substr(h, 1, 1)) - 1 AS HUGEINT) * CAST('21267647932558653966460912964485513216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 2, 1)) - 1 AS HUGEINT) * CAST('1329227995784915872903807060280344576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 3, 1)) - 1 AS HUGEINT) * CAST('83076749736557242056487941267521536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 4, 1)) - 1 AS HUGEINT) * CAST('5192296858534827628530496329220096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 5, 1)) - 1 AS HUGEINT) * CAST('324518553658426726783156020576256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 6, 1)) - 1 AS HUGEINT) * CAST('20282409603651670423947251286016' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 7, 1)) - 1 AS HUGEINT) * CAST('1267650600228229401496703205376' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 8, 1)) - 1 AS HUGEINT) * CAST('79228162514264337593543950336' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 9, 1)) - 1 AS HUGEINT) * CAST('4951760157141521099596496896' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 10, 1)) - 1 AS HUGEINT) * CAST('309485009821345068724781056' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 11, 1)) - 1 AS HUGEINT) * CAST('19342813113834066795298816' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 12, 1)) - 1 AS HUGEINT) * CAST('1208925819614629174706176' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 13, 1)) - 1 AS HUGEINT) * CAST('75557863725914323419136' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 14, 1)) - 1 AS HUGEINT) * CAST('4722366482869645213696' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 15, 1)) - 1 AS HUGEINT) * CAST('295147905179352825856' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 16, 1)) - 1 AS HUGEINT) * CAST('18446744073709551616' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 17, 1)) - 1 AS HUGEINT) * CAST('1152921504606846976' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 18, 1)) - 1 AS HUGEINT) * CAST('72057594037927936' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 19, 1)) - 1 AS HUGEINT) * CAST('4503599627370496' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 20, 1)) - 1 AS HUGEINT) * CAST('281474976710656' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 21, 1)) - 1 AS HUGEINT) * CAST('17592186044416' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 22, 1)) - 1 AS HUGEINT) * CAST('1099511627776' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 23, 1)) - 1 AS HUGEINT) * CAST('68719476736' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 24, 1)) - 1 AS HUGEINT) * CAST('4294967296' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 25, 1)) - 1 AS HUGEINT) * CAST('268435456' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 26, 1)) - 1 AS HUGEINT) * CAST('16777216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 27, 1)) - 1 AS HUGEINT) * CAST('1048576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 28, 1)) - 1 AS HUGEINT) * CAST('65536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 29, 1)) - 1 AS HUGEINT) * CAST('4096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 30, 1)) - 1 AS HUGEINT) * CAST('256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 31, 1)) - 1 AS HUGEINT) * CAST('16' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 32, 1)) - 1 AS HUGEINT) * CAST('1' AS HUGEINT) AS value,
         block_number
  FROM samples
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
