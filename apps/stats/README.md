<p align="center"><img src="logo.png" alt="clauderaptor stats logo: a raptor with glasses and a clipboard pointing at three little raptors" width="192"></p>

# clauderaptor stats

How effective the PR queue is: rounds to merge, first-pass yield, review cost, how often the judge confirms the
reviewers' findings, tokens and cache use from the Claude transcripts, and what to change. It reads the queue's
state and the transcripts into a local SQLite db and renders it as one self-contained HTML page, opened in its own
Edge app window under WSL.

## Install

    ~/code/clauderaptor/apps/stats/install.sh

It links `raptor-stats` into `${XDG_BIN_HOME:-~/.local/bin}` (and says so if that folder isn't on your PATH).
Nothing is copied, so a `git pull` of clauderaptor updates the app. `install.sh --uninstall` removes the link.

## Use

    raptor-stats [--windows-user NAME]

collects fresh stats (`stats.py ingest`), writes the report (`report.py`) and opens it from a small local
server (`serve.py open`). The parts on their own: `stats.py` (ingest, `stats.py -h`), `report.py` (render,
`report.py -h`; `report.py --open` opens the plain file, without Refresh) and `serve.py` (`serve.py -h`).

## Refresh

The window's header has a **Refresh** button and the time of the last ingest. Refresh runs the ingest and
rebuilds the report, then reloads the page; an error shows next to the button (the details are in `serve.log`).

The button needs `serve.py`, which `raptor-stats` starts in the background: Python's standard library only, on
`127.0.0.1` and a free port, for this stats folder. Running `raptor-stats` again while it is up reuses it and
opens another window. It answers only with a random token that it keeps in `serve.json` (0600) in the stats
folder, only for a Host of `127.0.0.1:<port>` or `localhost:<port>`, and a POST only from its own page. Edge gets
a one-time link, not the token. The page's script runs under a CSP nonce and can talk only to that server. The
page sends a heartbeat every minute; the server stops 10 minutes after its last request (`--idle`), so soon
after the window closes. Opened as a plain file, the page has no script and the button stays hidden.

## Data
The db and the report stay on this machine, in `${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/`, never in
a git checkout: `report.py` and `serve.py` refuse one, and the repo's pre-commit hook refuses stats data. So do the
server's `serve.json`, `serve.log` and `serve.lock`. The page loads nothing from the network: it talks only to its
own server on 127.0.0.1.
