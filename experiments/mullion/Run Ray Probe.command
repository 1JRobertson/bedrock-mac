#!/bin/sh
set -eu
cd -- "$(dirname -- "$0")"
python3 run.py inline-probe --compat --relaxed-level
python3 run.py probe --compat --relaxed-level
