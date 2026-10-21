#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
# The game validates both matching GPU-readback fingerprints before launch.
# User requested memory observation without threshold aborts for this experiment.
python3 run.py game --compat --relaxed-level --unguarded-game
