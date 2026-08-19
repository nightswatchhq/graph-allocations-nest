-- Lodestar's `PaymentsTx` shape (RFC-0011), served from PaymentsEscrow events.
--
-- Five money movements in one stream, with `type` doing the work the subgraph's
-- `paymentsEscrowTransactions` entity does. `allocationId` is NULL throughout and that is correct
-- rather than missing: escrow moves are payer/receiver level, no escrow event carries an allocation,
-- and Lodestar's own interface already types it as nullable.
--
-- `id` is `tx_hash-log_index`, which is stable, unique, and reproducible by anyone re-indexing the
-- same range - unlike a synthetic counter, which would depend on insertion order.
CREATE VIEW lodestar_escrow_transactions AS
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR) AS id,
       'Deposit'                    AS type,
       payer, receiver, collector,
       CAST(tokens AS HUGEINT)      AS amount,
       CAST(NULL AS VARCHAR)        AS allocation_id,
       block_timestamp              AS timestamp,
       block_number
FROM escrow__deposit
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR), 'Thaw',
       payer, receiver, collector, CAST("tokens" AS HUGEINT), NULL, block_timestamp, block_number
FROM escrow__thaw
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR), 'CancelThaw',
       payer, receiver, collector, CAST("tokensThawing" AS HUGEINT), NULL, block_timestamp, block_number
FROM escrow__cancel_thaw
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR), 'Withdraw',
       payer, receiver, collector, CAST(tokens AS HUGEINT), NULL, block_timestamp, block_number
FROM escrow__withdraw
UNION ALL
SELECT tx_hash || '-' || CAST(log_index AS VARCHAR), 'EscrowCollected',
       payer, receiver, collector, CAST(tokens AS HUGEINT), NULL, block_timestamp, block_number
FROM escrow__escrow_collected;
