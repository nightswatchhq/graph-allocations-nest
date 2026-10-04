#!/usr/bin/env bash
# Exact L2 start blocks for EpochManager epochs FROM..TO, for `exact_starts` in views/50-lodestar-epochs.sql.
#
# EpochManager counts L1 blocks: epoch(l1) = 92 + (l1 - 16687937) // 7200, one linear segment since the
# last length update at epoch 92. Each L1 start is mapped to the first L2 block whose header
# `l1BlockNumber` reaches it, by binary search. Every result is then checked against the contract:
# currentEpoch() is E at the start block and E-1 at the block before, which needs an archive RPC.
#
# Usage: scripts/epoch-starts.sh FROM TO [LO_L2_BLOCK]   (LO must sit before FROM's start; default the
# newest row already in the view). Prints view rows. Exits 1 on any mismatch or a changed epoch length.
set -euo pipefail
RPC=${RPC:-https://arb1.arbitrum.io/rpc}
ARCHIVE_RPC=${ARCHIVE_RPC:-https://arb-pokt.nodies.app}
EPOCHS=0x5a843145c43d328b9bb7a4401d94918f131bb281
from=$1 to=$2
lo=${3:-$(grep -oE '^ +\([0-9]+, [0-9]+\)' "$(dirname "$0")/../views/50-lodestar-epochs.sql" | tail -1 | grep -oE '[0-9]+\)$' | tr -d ')')}

rpc() {   # rpc PAYLOAD [URL]
  local out
  for _ in 1 2 3 4 5 6; do
    out=$(curl -fsS -m 30 -X POST -H 'content-type: application/json' --data "$1" "${2:-$RPC}" 2>/dev/null \
      | jq -er '.result // empty' 2>/dev/null) && { echo "$out"; return; }
    sleep 2
  done
  echo "rpc failed: $1" >&2; exit 1
}
call() {   # call SELECTOR BLOCK -> decimal
  local r
  r=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":[{\"to\":\"$EPOCHS\",\"data\":\"$1\"},\"$2\"]}" "$ARCHIVE_RPC") || exit 1
  echo $((r))
}
l1of() {
  local r
  r=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf 0x%x "$1")\",false]}") || exit 1
  r=$(jq -er .l1BlockNumber <<<"$r") || exit 1
  echo $((r))
}

# epochLength(), lastLengthUpdateBlock(), lastLengthUpdateEpoch(), currentEpoch()
len=$(call 0x57d775f8 latest) || exit 1
upd=$(call 0xcc65149b latest) || exit 1
upe=$(call 0xb4146a0b latest) || exit 1
[ "$len $upd $upe" = "7200 16687937 92" ] \
  || { echo "EpochManager's length parameters changed; the formula above no longer holds" >&2; exit 1; }
cur=$(call 0x76671808 latest) || exit 1
[ "$to" -le "$cur" ] || { echo "epoch $to has not started (current $cur)" >&2; exit 1; }
hi=$(rpc '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}') || exit 1
hi=$((hi))

for e in $(seq "$from" "$to"); do
  target=$((16687937 + (e - 92) * 7200))
  a=$lo b=$hi
  v=$(l1of "$a") || exit 1
  [ "$v" -lt "$target" ] || { echo "LO $a is not before epoch $e" >&2; exit 1; }
  while [ $((b - a)) -gt 1 ]; do
    m=$(((a + b) / 2))
    v=$(l1of "$m") || exit 1
    if [ "$v" -ge "$target" ]; then b=$m; else a=$m; fi
  done
  at=$(call 0x76671808 "$(printf 0x%x "$b")") || exit 1
  before=$(call 0x76671808 "$(printf 0x%x $((b - 1)))") || exit 1
  [ "$at" = "$e" ] && [ "$before" = "$((e - 1))" ] \
    || { echo "epoch $e at $b: currentEpoch() $at, at $((b - 1)) $before" >&2; exit 1; }
  printf '    (%s, %s),\n' "$e" "$b"
  lo=$b
done
