-- `lodestar_indexer_pool` and `lodestar_indexers` both report the delegation pool, and they must
-- never disagree: an indexer page and a delegator page would then show different numbers for the
-- same indexer. The pool view exists because `lodestar_delegator_stakes` wanted two of the forty
-- columns `lodestar_indexers` computes; this check is what makes that duplication safe.
--
-- Expect zero rows. Any row is a drift between the two definitions of `delegated_tokens` or
-- `delegator_shares`.
SELECT i.id,
       p.delegator_shares AS pool_shares,   i.delegator_shares AS indexers_shares,
       p.delegated_tokens AS pool_tokens,   i.delegated_tokens AS indexers_tokens
FROM lodestar_indexer_pool p
JOIN lodestar_indexers i ON i.id = p.id
WHERE p.delegator_shares IS DISTINCT FROM i.delegator_shares
   OR p.delegated_tokens IS DISTINCT FROM i.delegated_tokens;
