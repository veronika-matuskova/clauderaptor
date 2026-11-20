#!/usr/bin/env python3
"""Claude Code statusline (ported from statusline-community Fvv6W_hatC.ps1)."""
import json, math, os, subprocess, sys, time

RAW = sys.stdin.read()
try:
    j = json.loads(RAW)
except Exception:
    j = {}

def f(path):
    cur = j
    for p in path.split('.'):
        if not isinstance(cur, dict) or p not in cur or cur[p] is None:
            return ''
        cur = cur[p]
    if isinstance(cur, bool):
        return 'true' if cur else 'false'
    return str(cur)

def num(v, default=0.0):
    try: return float(v)
    except (TypeError, ValueError): return default

def i(v): return max(0, int(num(v)))

out = []
def emit(codes, text):
    out.append(f"\x1b[{codes}m{text}\x1b[0m" if codes else text)

# Context thresholds (tokens) and their colours; marked as separators in the bar.
LIMITS = [(100_000, '38;5;226'), (200_000, '38;5;214'), (500_000, '38;5;167')]

def bar(pct, color, width=20):
    """Bar with a separator at each limit that falls inside the context window."""
    p = min(100.0, max(0.0, num(pct)))
    n = round(p * width / 100)
    cells = [(color, '█') if k < n else ('', '░') for k in range(width)]
    size = num(f('context_window.context_window_size'))
    if size > 0:
        for limit, lc in LIMITS:
            pos = round(limit * width / size)
            if 0 < pos < width:
                cells[pos] = ('1;' + lc, '│')
    return ''.join(f"[{c}m{t}[0m" if c else t for c, t in cells)

def tok(v):
    n = i(v)
    if n < 1000: return str(n)
    if n < 1_000_000:
        w, d = n // 1000, (n % 1000) // 100
        return f"{w}k" if d == 0 else f"{w}.{d}k"
    w, d = n // 1_000_000, (n % 1_000_000) // 100_000
    return f"{w}M" if d == 0 else f"{w}.{d}M"

def dur(ms):
    t = i(ms) // 1000
    if t < 60: return f"{t}s"
    m, s = divmod(t, 60)
    if m < 60: return f"{m}m {s}s" if s else f"{m}m"
    h, mm = divmod(m, 60)
    return f"{h}h {mm}m" if mm else f"{h}h"

def rel(v):
    if not v: return ''
    diff = math.floor(num(v) - time.time())
    if diff <= 0: return ''
    if diff < 60: return f"T-{diff}s"
    if diff < 3600: return f"T-{diff // 60}m{diff % 60:02d}s"
    return f"T-{diff // 3600}h{(diff % 3600) // 60:02d}m"

def git(*args):
    cwd = f('workspace.current_dir') or f('cwd')
    if not cwd: return ''
    try:
        return subprocess.run(['git', '-C', cwd, *args], capture_output=True,
                              text=True, timeout=2).stdout.strip()
    except Exception:
        return ''

# Line 1: model | effort | context bar | tokens | duration | cost
emit('1', f('model.display_name')); emit('', ' | ')
if f('thinking.enabled') == 'true':
    emit('', f('effort.level'))
emit('', ' | ')
used = num(f('context_window.total_input_tokens'))
color = '38;5;167' if used > 500000 else '38;5;214' if used > 200000 else '38;5;226' if used > 100000 else '38;5;114'
emit('', bar(f('context_window.used_percentage'), color))
emit('', ' | ')
emit('', f"{tok(f('context_window.total_input_tokens'))}/{tok(f('context_window.context_window_size'))} ({i(f('context_window.used_percentage'))}%)")
emit('', ' | '); emit('', dur(f('cost.total_duration_ms')))
emit('', ' | '); emit('', f"${num(f('cost.total_cost_usd')):.2f}")
out.append('\n')

# Line 2: cwd | branch | dirty
cwd = f('workspace.current_dir'); home = os.path.expanduser('~')
emit('', '~' + cwd[len(home):] if home and cwd.startswith(home) else cwd)
emit('', ' | '); emit('', git('rev-parse', '--abbrev-ref', 'HEAD') or f('workspace.git_worktree'))
emit('', ' | ')
emit('1;38;2;206;73;73', '✗') if git('status', '--porcelain') else emit('1;38;2;37;153;56', '✓')
out.append('\n')

# Line 3: rate limits as "label left% - time until reset"
def until(v):
    if not v: return ''
    t = math.floor(num(v) - time.time())
    if t <= 0: return ''
    d, t = divmod(t, 86400); h, t = divmod(t, 3600); m = t // 60
    return ' '.join(x for x in (f"{d}d" if d else '', f"{h}h" if d or h else '', f"{m}m") if x)

def limit(label, key):
    used = f(f'rate_limits.{key}.used_percentage')
    if used == '': return f"{label} --"
    left = max(0, 100 - round(num(used)))
    color = '38;5;114' if left > 50 else '38;5;226' if left > 20 else '38;5;167'
    reset = until(f(f'rate_limits.{key}.resets_at'))
    return f"{label} [{color}m{left}%[0m" + (f" - {reset}" if reset else '')

out.append(limit('7d:', 'seven_day') + ' | ' + limit('5h:', 'five_hour'))

sys.stdout.write(''.join(out))
