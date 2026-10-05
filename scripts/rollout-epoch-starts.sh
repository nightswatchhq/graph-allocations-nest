#!/usr/bin/env bash
# Install this checkout's views/50-lodestar-epochs.sql on production (8107, graph-allocations-nest-next).
#
# Production must be running the file as it stands at BASE (default origin/main), or already this one;
# anything else stops before a byte is written. Only that one file changes.
#
# No restart and no re-index: /sql reads views/*.sql from disk per statement and its memo keys on
# their content, and views/ is outside the nest's data identity. /nest keeps reporting the old NID
# until the next restart, which is cosmetic in a solo nest dir.
#
# Checked after install: epoch 1390's query_fees_collected is still the subgraph's value, and the
# newest row of exact_starts reads back as an l1-exact boundary. Either failing restores the backup.
set -euo pipefail

HOST=${HOST:-root@89.167.109.4}
KEY=${KEY:-$HOME/.ssh/hetzner_drpc}
BASE=${BASE:-origin/main}
NEST=/opt/nuthatch/graph-allocations-nest-next
PORT=8107
FILE=views/50-lodestar-epochs.sql
WANT=2981030500877230556383   # the subgraph's queryFeesCollected for epoch 1390

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/$FILE"
NEW=$(shasum -a 256 "$src" | cut -d' ' -f1)
OLD=$(git -C "$root" show "$BASE:$FILE" | shasum -a 256 | cut -d' ' -f1)
read -r last_epoch last_start < <(grep -oE '^ +\([0-9]+, [0-9]+\)' "$src" | tail -1 | tr -d '(),')
[ -n "$last_epoch" ] && [ -n "$last_start" ] || { echo "no exact_starts rows in $FILE" >&2; exit 1; }

# Outside the nest dir: a directory inside it would join the nest's identity.
bak="$NEST.views-bak-$(date -u +%Y%m%dT%H%M%SZ)"
remote() { ssh -i "$KEY" -o BatchMode=yes "$HOST" "$@"; }
restore() { remote "cp -p $bak/50-lodestar-epochs.sql $NEST/$FILE"; }

remote "set -e
  cur=\$(sha256sum $NEST/$FILE | cut -d' ' -f1)
  [ \"\$cur\" = $OLD ] || [ \"\$cur\" = $NEW ] || { echo \"production $FILE is \$cur, not $BASE's ($OLD); stopping\" >&2; exit 1; }
  curl -fsS -m 10 127.0.0.1:$PORT/ready >/dev/null || { echo '$PORT is not ready; stopping' >&2; exit 1; }
  cp -a $NEST/views $bak"
echo "backed up $NEST/views to $bak"

remote "set -e
  cat > $NEST/views/.50-lodestar-epochs.new
  chown --reference=$NEST/$FILE $NEST/views/.50-lodestar-epochs.new
  chmod --reference=$NEST/$FILE $NEST/views/.50-lodestar-epochs.new
  mv -f $NEST/views/.50-lodestar-epochs.new $NEST/$FILE
  [ \"\$(sha256sum $NEST/$FILE | cut -d' ' -f1)\" = $NEW ]" < "$src" || { restore; echo "install failed; restored" >&2; exit 1; }
echo "installed $FILE ($NEW)"

q() { remote "curl -sS -m 300 -G 127.0.0.1:$PORT/sql --data-urlencode 'q=$1'"; }
fees=$(q "SELECT query_fees_collected FROM lodestar_epochs WHERE id = 1390" | jq -r '.rows[0].query_fees_collected // .error // "no answer"')
edge=$(q "SELECT start_block, boundary_source FROM epoch_boundaries WHERE epoch = $last_epoch" \
  | jq -r '(.rows[0] | "\(.start_block) \(.boundary_source)") // .error // "no answer"')
if [ "$fees" = "$WANT" ] && [ "$edge" = "$last_start l1-exact" ]; then
  echo "ok: epoch 1390 query_fees_collected = $fees; epoch $last_epoch starts at $last_start, l1-exact"
  echo "rollback, if wanted: ssh -i $KEY $HOST 'cp -p $bak/50-lodestar-epochs.sql $NEST/$FILE'"
else
  restore
  echo "FAILED: epoch 1390 read '$fees' (want $WANT), epoch $last_epoch read '$edge' (want $last_start l1-exact); restored $bak" >&2
  exit 1
fi
