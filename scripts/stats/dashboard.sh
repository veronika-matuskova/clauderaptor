#!/usr/bin/env bash
# Collects the queue's stats and opens them: stats.py ingest into the default db, then report.py --open (an Edge
# app window under WSL). Arguments go to report.py, e.g. --windows-user NAME.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I -B "$here/stats.py" ingest
exec python3 -I -B "$here/report.py" --open "$@"
