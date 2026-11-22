#!/usr/bin/env bash
# Collects the queue's stats and opens them: stats.py ingest into the default db, then report.py --open (an Edge
# app window under WSL). Arguments go to report.py, e.g. --windows-user NAME. install.sh links it as raptor-stats.
set -euo pipefail
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"  # the real folder, also when run through the raptor-stats link
python3 -I -B "$here/stats.py" ingest
exec python3 -I -B "$here/report.py" --open "$@"
