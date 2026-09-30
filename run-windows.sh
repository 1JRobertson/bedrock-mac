#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LC_ALL=en_US.UTF-8
export CX_BOTTLE_PATH="$ROOT/bottles"
exec "$ROOT/runtime/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine" \
  --bottle Bedrock-Mac --workdir "$ROOT/game" \
  --dll 'xgameruntime=b;windows.web,twinapi.appcore,windows.ui.core.textinput,wintypes=n' --debugmsg '-all' "$@"
