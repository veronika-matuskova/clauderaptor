#!/usr/bin/env bash
# Collects the queue's stats and opens them: stats.py ingest into the default db, report.py into report.html next
# to it, then serve.py open: the report from a local server on 127.0.0.1 (reused if one runs for this stats
# folder), in an Edge app window under WSL, with a Refresh button. Arguments go to serve.py open, e.g.
# --windows-user NAME. install.sh links it as raptor-stats.
set -euo pipefail
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"  # the real folder, also when run through the raptor-stats link
python3 -I -B "$here/stats.py" ingest
python3 -I -B "$here/report.py"
exec python3 -I -B "$here/serve.py" open "$@"
