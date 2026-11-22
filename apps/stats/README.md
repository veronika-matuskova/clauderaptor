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

collects fresh stats (`stats.py ingest`) and opens the report (`report.py --open`). The parts on their own:
`stats.py` (ingest, `stats.py -h`) and `report.py` (render, `report.py -h`).

## Data
The db and the report stay on this machine, in `${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/`, never in
a git checkout: `report.py` refuses to write into one, and the repo's pre-commit hook refuses stats data. The page
loads nothing from the network.
