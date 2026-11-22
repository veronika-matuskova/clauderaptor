#!/usr/bin/env python3
"""A tiny local server for the stats report, so that its Refresh button can run the ingest.

  serve.py open [--db PATH] [--out PATH] [--projects DIR] [--idle SECONDS] [--windows-user NAME]
  serve.py run  [--db PATH] [--out PATH] [--projects DIR] [--idle SECONDS]

open (what raptor-stats runs): reuses the server of this stats folder if one answers, else starts `run`
detached, and opens the report in an Edge app window (report.py's Edge and profile); outside WSL it prints a
link to open. run: the server itself. --db defaults to stats.py's db, --out to report.html next to the db (which
report.py writes first), --projects goes to stats.py ingest, --idle (default 600) is how long the server stays
up without an authorized request: the page sends a heartbeat every 60 s, so an open window keeps it up, and it
stops at most --idle seconds after the window closes.

The server binds 127.0.0.1 on a free port and makes a random token (secrets.token_urlsafe). Every request needs
a Host of 127.0.0.1:<port> or localhost:<port> (against DNS rebinding) and the token, else 403:
- GET /?t=<token>, or GET /?k=<ticket>: the report file as a page with a CSP nonce, the script and the token
  (report.served_page). A ticket is a link for one Edge window: it works once, for 2 minutes.
- POST /refresh, /heartbeat or /ticket with the header X-Raptor-Token: <token>, and no Origin or the page's own
  (http://<Host>): /refresh runs stats.py ingest and report.py --out (subprocesses), one at a time (409 while one
  runs), and says {"ok": ...} with a short message, never a traceback or a path (those go to the log);
  /heartbeat keeps the server up; /ticket makes a ticket (what open asks for).
Other paths are 404, other methods 501.
The token never goes into a process's arguments nor a world-readable file: the server writes it, with its pid
and port, to serve.json in the stats folder (0600; removed when it stops), and open reads it from there. Edge
gets a ticket, not the token. The log, serve.log (0600, new for each server), has no query strings.
The stats folder is never in a git work tree: serve.py refuses one (exit 2), like stats.py.
"""
import argparse
import contextlib
import fcntl
import hmac
import http.client
import http.server
import importlib.util
import json
import os
import secrets
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

sys.dont_write_bytecode = True  # importing report.py leaves no __pycache__ in the checkout
HERE = os.path.dirname(os.path.realpath(__file__))
_spec = importlib.util.spec_from_file_location("clauderaptor_report", os.path.join(HERE, "report.py"))
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)
stats = report.stats

IDLE = 600  # seconds without an authorized request, then the server stops
TICKET_TTL = 120
REFRESH_TIMEOUT = 900  # each of the ingest and the rebuild
START_TIMEOUT = 15  # for a new server to say it's ready
MAX_BODY = 4096
TOKEN_HEADER = "X-Raptor-Token"
POST_PATHS = ("/refresh", "/heartbeat", "/ticket")


def die(msg, code=2):
    print("serve: " + msg, file=sys.stderr)
    sys.exit(code)


_log_lock = threading.Lock()


def log(msg):
    with _log_lock:
        print("%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), file=sys.stderr, flush=True)


def files(db):
    """The server's files, next to the db: serve.json (pid, port, token), serve.log, serve.lock."""
    d = os.path.dirname(os.path.abspath(db))
    return {k: os.path.join(d, "serve." + k) for k in ("json", "log", "lock")}


def refuse_work_tree(path):
    tree = stats.work_tree_of(path)
    if tree:
        die("refusing to keep %s: it is inside the git work tree %s, and the stats never go into a repo. "
            "Use a path outside any checkout (--db or CLAUDERAPTOR_STATS_DIR)." % (path, tree))


def write_private(path, text):
    """The file 0600, atomically."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".serve-", suffix=".tmp")  # 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_state(path):
    """serve.json's pid, port and token, or None."""
    try:
        with open(path, encoding="utf-8") as fh:
            st = json.load(fh)
        if isinstance(st.get("pid"), int) and isinstance(st.get("port"), int) and isinstance(st.get("token"), str):
            return st
    except (OSError, ValueError, AttributeError):
        pass
    return None


@contextlib.contextmanager
def locked(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


# --- the server -----------------------------------------------------------------------------------------------

class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, db, out, projects, idle):
        super().__init__(("127.0.0.1", 0), Handler)
        self.port = self.server_address[1]
        self.token = secrets.token_urlsafe(32)
        self.hosts = {"127.0.0.1:%d" % self.port, "localhost:%d" % self.port}
        self.db, self.out, self.projects, self.idle = db, out, projects, idle
        self.tickets = {}  # ticket -> when it expires (monotonic)
        self.lock = threading.Lock()  # self.tickets and self.last
        self.refreshing = threading.Lock()
        self.last = time.monotonic()

    def authorized(self, token):
        return isinstance(token, str) and hmac.compare_digest(token.encode("utf-8", "replace"),
                                                              self.token.encode("ascii"))

    def touch(self):
        with self.lock:
            self.last = time.monotonic()

    def new_ticket(self):
        t = secrets.token_urlsafe(32)
        with self.lock:
            now = time.monotonic()
            self.tickets = {k: v for k, v in self.tickets.items() if v > now}
            self.tickets[t] = now + TICKET_TTL
        return t

    def use_ticket(self, t):
        with self.lock:
            expires = self.tickets.pop(t, None)
        return expires is not None and expires > time.monotonic()

    def refresh(self):
        """(status, reply) of an ingest and a rebuild of the report: 409 while another runs."""
        if not self.refreshing.acquire(blocking=False):
            return 409, {"ok": False, "error": "a refresh is already running"}
        try:
            steps = (("ingest", [sys.executable, "-I", "-B", os.path.join(HERE, "stats.py"), "ingest", "--db",
                                 self.db] + (["--projects", self.projects] if self.projects else [])),
                     ("rebuild", [sys.executable, "-I", "-B", os.path.join(HERE, "report.py"), "--db", self.db,
                                  "--out", self.out]))
            for name, cmd in steps:
                try:
                    r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                       timeout=REFRESH_TIMEOUT)
                except subprocess.TimeoutExpired:
                    log("refresh: the %s took over %d s" % (name, REFRESH_TIMEOUT))
                    return 500, {"ok": False, "error": "the %s took too long; see serve.log in the stats folder" % name}
                except OSError as ex:
                    log("refresh: the %s did not start: %s" % (name, ex))
                    return 500, {"ok": False, "error": "the %s did not start; see serve.log in the stats folder" % name}
                if r.returncode:
                    log("refresh: the %s failed (exit %d):\n%s%s" % (name, r.returncode, r.stdout, r.stderr))
                    return 500, {"ok": False, "error": "the %s failed (exit %d); see serve.log in the stats folder"
                                 % (name, r.returncode)}
            log("refresh: done")
            return 200, {"ok": True, "message": "refreshed"}
        finally:
            self.touch()  # before the release: the idle watch never stops a server that just refreshed
            self.refreshing.release()

    def watch_idle(self, stop):
        while not stop.wait(min(1.0, self.idle / 4)):
            with self.lock:
                idle_for = time.monotonic() - self.last
            if idle_for >= self.idle and not self.refreshing.locked():
                log("idle for %d s: stopping" % idle_for)
                self.shutdown()
                return


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "raptor-stats"
    sys_version = ""
    timeout = 15  # a client that sends nothing doesn't hold a thread

    # Logged without the query string or headers: they hold the token or a ticket.
    def log_request(self, code="-", size="-"):
        log("%s %s %s" % (self.command, urllib.parse.urlsplit(self.path or "").path[:200], code))

    def log_error(self, *args):
        pass  # log_request has the status; the default message repeats the request line

    def reply(self, code, obj=None, body=None, ctype="application/json", headers=()):
        data = body if body is not None else json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def forbidden(self):
        self.reply(403, {"ok": False, "error": "forbidden"})

    def host(self):
        """The Host header if it is this server's (127.0.0.1 or localhost with its port), else None."""
        hosts = self.headers.get_all("Host") or []
        return hosts[0] if len(hosts) == 1 and hosts[0] in self.server.hosts else None

    def do_GET(self):
        srv = self.server
        if not self.host():
            return self.forbidden()
        u = urllib.parse.urlsplit(self.path)
        if u.path != "/":
            return self.reply(404, {"ok": False, "error": "not found"})
        q = urllib.parse.parse_qs(u.query, keep_blank_values=True)
        t, k = q.get("t", []), q.get("k", [])
        if not ((len(t) == 1 and not k and srv.authorized(t[0])) or (len(k) == 1 and not t and srv.use_ticket(k[0]))):
            return self.forbidden()
        srv.touch()
        try:
            with open(srv.out, encoding="utf-8") as fh:
                page = fh.read()
        except OSError:
            return self.reply(503, body=b"no report yet: run raptor-stats\n", ctype="text/plain")
        nonce = secrets.token_urlsafe(18)
        try:
            html = report.served_page(page, nonce, srv.token)
        except ValueError:
            return self.reply(500, body=b"the report file is not a report page: run raptor-stats\n",
                              ctype="text/plain")
        self.reply(200, body=html.encode("utf-8"), ctype="text/html", headers=(
            ("Content-Security-Policy", report.csp_served(nonce) + "; frame-ancestors 'none'"),
            ("X-Frame-Options", "DENY")))

    def do_POST(self):
        srv = self.server
        host = self.host()
        if not host:
            return self.forbidden()
        u = urllib.parse.urlsplit(self.path)
        if u.path not in POST_PATHS or u.query:
            return self.reply(404, {"ok": False, "error": "not found"})
        origins = self.headers.get_all("Origin")
        if origins is not None and (len(origins) != 1 or origins[0] != "http://" + host):
            return self.forbidden()
        if not srv.authorized(self.headers.get(TOKEN_HEADER)):
            return self.forbidden()
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if not 0 <= n <= MAX_BODY:
            return self.reply(413, {"ok": False, "error": "body too large"})
        self.rfile.read(n)  # nothing in it is used
        srv.touch()
        if u.path == "/heartbeat":
            return self.reply(200, {"ok": True})
        if u.path == "/ticket":
            return self.reply(200, {"ok": True, "ticket": srv.new_ticket()})
        self.reply(*srv.refresh())


def run(a, db, out):
    p = files(db)
    srv = Server(db, out, a.projects, a.idle)
    write_private(p["json"], json.dumps({"pid": os.getpid(), "port": srv.port, "token": srv.token}))
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: threading.Thread(target=srv.shutdown, daemon=True).start())
    stop = threading.Event()
    threading.Thread(target=srv.watch_idle, args=(stop,), daemon=True).start()
    print("ready %d" % srv.port, flush=True)
    os.dup2(2, 1)  # from here on stdout goes to the log too: open's pipe sees the end
    log("serving on 127.0.0.1:%d, idle timeout %d s" % (srv.port, a.idle))
    try:
        srv.serve_forever(poll_interval=0.25)
    finally:
        stop.set()
        srv.refreshing.acquire(timeout=REFRESH_TIMEOUT)  # a refresh that is running ends first
        srv.server_close()
        with locked(p["lock"]):
            st = read_state(p["json"])
            if st and st["pid"] == os.getpid():
                os.unlink(p["json"])
        log("stopped")


# --- open: reuse or start a server, and an Edge window ------------------------------------------------------------

def ask_ticket(st):
    """A ticket from the server serve.json names, or None if it doesn't answer as that server."""
    try:
        c = http.client.HTTPConnection("127.0.0.1", st["port"], timeout=5)
        c.request("POST", "/ticket", headers={TOKEN_HEADER: st["token"]})
        r = c.getresponse()
        d = json.loads(r.read().decode("utf-8")) if r.status == 200 else {}
        c.close()
    except (OSError, ValueError, http.client.HTTPException):
        return None
    t = d.get("ticket") if isinstance(d, dict) else None
    return t if isinstance(t, str) and report.SAFE.fullmatch(t) else None


def start(a, db, out, p):
    """A new detached server: its state, once it said it's ready."""
    logfd = os.open(p["log"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(logfd, 0o600)
    cmd = [sys.executable, "-I", "-B", os.path.realpath(__file__), "run", "--db", db, "--out", out,
           "--idle", str(a.idle)] + (["--projects", a.projects] if a.projects else [])
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=logfd,
                                start_new_session=True, close_fds=True)
    finally:
        os.close(logfd)
    line = b""
    deadline = time.monotonic() + START_TIMEOUT
    while not line.endswith(b"\n") and time.monotonic() < deadline:
        if not select.select([proc.stdout], [], [], max(0.0, deadline - time.monotonic()))[0]:
            break
        chunk = os.read(proc.stdout.fileno(), 64)
        if not chunk:
            break
        line += chunk
    proc.stdout.close()
    st = read_state(p["json"])
    if not line.startswith(b"ready ") or not st or st["pid"] != proc.pid:
        if proc.poll() is None:
            proc.kill()
        die("the server did not start; see %s" % p["log"], 1)
    return st


def open_window(a, db, out):
    if not os.path.isfile(out):
        die("no report at %s: run apps/stats/report.py first" % out)
    edge, wslpath, missing = report.find_edge()
    profile = report.edge_profile(wslpath, a.windows_user) if edge else None  # before a server: it may refuse
    p = files(db)
    with locked(p["lock"]):
        st = read_state(p["json"])
        ticket = ask_ticket(st) if st else None
        if ticket:
            print("report: reusing the server at http://127.0.0.1:%d/ (pid %d)" % (st["port"], st["pid"]))
        else:
            st = start(a, db, out, p)
            ticket = ask_ticket(st)
            if not ticket:
                die("the server does not answer; see %s" % p["log"], 1)
            print("report: serving it at http://127.0.0.1:%d/ (pid %d; it stops %d s after its last request)"
                  % (st["port"], st["pid"], a.idle))
    url = "http://127.0.0.1:%d/?k=%s" % (st["port"], ticket)
    if edge:
        report.launch_edge(edge, url, profile)
        print("report: opening it in an Edge app window")
    else:
        print("report: open %s in a browser; the link works once, for %d s (an Edge app window opens only under "
              "WSL: %s not found)" % (url, TICKET_TTL, missing))


def main(argv):
    ap = argparse.ArgumentParser(prog="serve.py", description="A local server for the stats report's Refresh.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, desc in (("open", "reuse or start the server and open the report in an Edge app window"),
                       ("run", "the server itself (what open starts)")):
        p = sub.add_parser(name, help=desc)
        p.add_argument("--db", default=None, help="the stats db (default: %s)" % stats.default_db())
        p.add_argument("--out", default=None, help="the report file (default: report.html next to the db)")
        p.add_argument("--projects", default=None, help="Claude Code's transcripts, for stats.py ingest")
        p.add_argument("--idle", type=int, default=IDLE, help="seconds without a request before it stops")
        if name == "open":
            p.add_argument("--windows-user", default=os.environ.get("CLAUDERAPTOR_WINDOWS_USER") or None,
                           help="the Windows user whose Edge profile folder to use, when several have one")
    a = ap.parse_args(argv)
    if a.idle < 1:
        die("--idle must be at least 1")
    os.umask(0o077)
    db = os.path.abspath(a.db or stats.default_db())
    out = os.path.abspath(a.out or os.path.join(os.path.dirname(db), "report.html"))
    if a.projects:
        a.projects = os.path.abspath(a.projects)
    refuse_work_tree(db)
    refuse_work_tree(out)
    if not os.path.isfile(db):
        die("no stats db at %s: run apps/stats/stats.py ingest first" % db)
    if a.cmd == "run":
        run(a, db, out)
    else:
        open_window(a, db, out)


if __name__ == "__main__":
    main(sys.argv[1:])
