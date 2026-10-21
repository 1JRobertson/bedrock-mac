#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
# The game validates both matching GPU-readback fingerprints before launch.
python3 run.py game --compat --relaxed-level
