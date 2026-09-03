---
name: nuthatch
description: Query this self-hosted nuthatch nest on arbitrum-one - decoded events, balances, and read-only SQL. Use when asked about on-chain activity for these contracts.
---

# Querying the nuthatch nest

Contracts indexed on arbitrum-one:
- `subgraph_service` = 0xb2bb92d0de618878e438b55d5846cfecd9301105
- `curation` = 0x22d78fb4bc72e191c765807f8891b5e1785c8014
- `epochs` = 0x5a843145c43d328b9bb7a4401d94918f131bb281
- `disputes` = 0x2fe023a575449acb698648ed21276293fa176f96
- `escrow` = 0xf6fcc27aaf1fcd8b254498c9794451d82afc673e
- `staking` = 0x00669a4cf01450b64e8a2a20e9b1fcb71e61ef03
- `staking_legacy` = 0x00669a4cf01450b64e8a2a20e9b1fcb71e61ef03
- `gns` = 0xec9a7fb6cbc2e41926127929c2dce6e9c5d33bec

Data is local - never call an external API for it.

## Preferred: MCP
If a `nuthatch` MCP server is configured, use its tools. Call `schema` first to learn the
data model, then `sql` / `entity` / `balance` / `top_balances`.

## Fallback: HTTP (a `nuthatch dev` must be running)
- Recent rows:  `curl localhost:8288/entities?limit=20`
- Read-only SQL: `curl -G localhost:8288/sql --data-urlencode 'q=SELECT count(*) FROM transfers'`

`sql` sees finalized data only; balances/entity cover the live tip.
