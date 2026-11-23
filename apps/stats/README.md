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

## Layout

A sticky row of quick links at the top leads to each section, and each section can be collapsed by clicking its
heading. The served page remembers collapsed sections across Refresh (the plain file starts with all open). From
a 1200px window the page shows two columns: Queue now, Headline, Cost and tokens, Timeline and By repo span both,
Rework sits next to Review value and What to change next to Data. Charts never render larger than in one column
(722px); tables use the section's full width. The theme picker in the link row switches between Default and Iris
(skydeck's palette, MIT); the served page keeps the choice in a cookie on 127.0.0.1, so it survives Refresh and a
new `raptor-stats` run (which gets a new port).

## Queue now

The report's first section shows what the PR queue is doing right now, per repo: the running branch, its step
(merging main, code review, test review, judge, e2e, waiting for CI, merging) and for how long; the queued
branches in order, with their wait; and the last failures that nobody has re-queued yet (5 per repo, "needs your
decision" marked). It is read from the queue's files (`$PR_QUEUE_DIR`) each time the report is built, not from
the db, so Refresh shows the current queue; "As of" says when that was.

## Milestones

A milestone is a commit on a repo's main that splits the stats into before and after, such as the merge of a
rule change. The report's "Before and after" section shows, for each one, side by side: the share of the test
reviews' categorised findings that are surviving mutations (and how many per test review), the share of the
judge's rulings it confirms for test-review and for code-review findings, and first-pass yield, each with its n.
All repos count together.

To add one, append an entry to `apps/stats/milestones.json` (a committed list, `[]` at first) once its commit is
on main, and run `raptor-stats` (or Refresh):

    [{"name": "test rules (17a-17c)", "repo": "clauderaptor", "commit": "<sha of the last merge>"}]

Its time is that commit's time on the repo's main; until the commit is there, the report lists it as "not on main
yet". A branch counts by when its first round started (the round-1 job's start, else its queue time, else its
end), so a branch started before the milestone stays "before" even when it merges after it; its reviews count
with it, and a review without a job by its own time. With several milestones, each one's "before" runs from the
previous milestone (or the beginning of the data) and its "after" to the next one (or now).

## Data
The db and the report stay on this machine, in `${XDG_STATE_HOME:-~/.local/state}/clauderaptor-stats/`, never in
a git checkout: `report.py` and `serve.py` refuse one, and the repo's pre-commit hook refuses stats data. So do the
server's `serve.json`, `serve.log` and `serve.lock`. The page loads nothing from the network: it talks only to its
own server on 127.0.0.1.
