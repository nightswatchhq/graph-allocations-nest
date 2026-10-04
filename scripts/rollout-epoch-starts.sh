#!/usr/bin/env bash
# Install the 1401 epoch table on production (8107, graph-allocations-nest-next), from Chief's Mac.
#
# Production runs #28's portable views on burrmill, so the file installed is #28's
# views/50-lodestar-epochs.sql with #29's table, as this branch merges them. #29's own file keeps the
# ASOF joins and does not load on 4.4.0. Only that one file changes; 95 stays at the pre-#24 version
# because production's nuthatch.toml does not index RewardsDenylistUpdated.
#
# No restart and no re-index: /sql reads views/*.sql from disk per statement and its memo keys on
# their content, and views/ is outside the nest's data identity. /nest keeps reporting the old NID
# until the next restart, which is cosmetic in a solo nest dir.
set -euo pipefail

HOST=${HOST:-root@89.167.109.4}
KEY=${KEY:-$HOME/.ssh/hetzner_drpc}
NEST=/opt/nuthatch/graph-allocations-nest-next
PORT=8107
FILE=views/50-lodestar-epochs.sql
OLD=f5d6cd920b4d20da8451e9a37ca80422c17c095adbb7fb0f5543955feb3eb5ad   # #28's file, what 8107 runs
NEW=283d7a11d2acba5cf92f54f0772f4492709b409df793d09f556ac1b6d6aa86f3   # #28 + #29's table
WANT=2981030500877230556383   # the subgraph's queryFeesCollected for epoch 1390

src="$(cd "$(dirname "$0")/.." && pwd)/$FILE"
# Outside the nest dir: a directory inside it would join the nest's identity.
bak="$NEST.views-bak-$(date -u +%Y%m%dT%H%M%SZ)"
remote() { ssh -i "$KEY" -o BatchMode=yes "$HOST" "$@"; }
rollback="ssh -i $KEY $HOST 'cp -p $bak/50-lodestar-epochs.sql $NEST/$FILE'"

have=$(shasum -a 256 "$src" | cut -d' ' -f1)
[ "$have" = "$NEW" ] || { echo "local $FILE is $have, not the reconciled file; check out pete/epoch-starts-rollout" >&2; exit 1; }

remote "set -e
  cur=\$(sha256sum $NEST/$FILE | cut -d' ' -f1)
  [ \"\$cur\" = $OLD ] || [ \"\$cur\" = $NEW ] || { echo \"production $FILE is \$cur, not the expected #28 file; stopping\" >&2; exit 1; }
  cp -a $NEST/views $bak"
echo "backed up $NEST/views to $bak"
echo "rollback: $rollback"

remote "set -e
  cat > $NEST/views/.50-lodestar-epochs.new
  chown --reference=$NEST/$FILE $NEST/views/.50-lodestar-epochs.new
  chmod --reference=$NEST/$FILE $NEST/views/.50-lodestar-epochs.new
  mv -f $NEST/views/.50-lodestar-epochs.new $NEST/$FILE
  [ \"\$(sha256sum $NEST/$FILE | cut -d' ' -f1)\" = $NEW ]" < "$src"
echo "installed $FILE ($NEW)"

got=$(remote "curl -sS -m 300 -G 127.0.0.1:$PORT/sql --data-urlencode 'q=SELECT query_fees_collected FROM lodestar_epochs WHERE id = 1390'" \
  | jq -r '.rows[0].query_fees_collected // .error // "no answer"')
if [ "$got" = "$WANT" ]; then
  echo "ok: epoch 1390 query_fees_collected = $got, the subgraph's value"
  echo "rollback, if wanted: $rollback"
else
  echo "FAILED: epoch 1390 query_fees_collected read '$got', want $WANT" >&2
  echo "rollback: $rollback" >&2
  exit 1
fi
