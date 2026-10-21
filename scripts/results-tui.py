#!/usr/bin/env python3
"""Browse the lab's measurements in the terminal.

  results-tui.py [RESULTS_DIR]          interactive (curses)
  results-tui.py --plain [RESULTS_DIR]  print the latest run of every scenario

Keys: up/down or j/k choose a run, PgUp/PgDn or J/K scroll the detail,
r reload, t raw JSON, q quit. Standard library only.
"""
import curses
import glob
import json
import os
import sys
from datetime import datetime, timezone

BAR = 24

# ── data ────────────────────────────────────────────────────────────────────────


def load_runs(directory):
    runs = []
    for path in glob.glob(os.path.join(directory, "*.json")):
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        runs.append({"path": path, "name": os.path.basename(path), "data": data,
                     "scenario": data.get("scenario", "?")})
    runs.sort(key=lambda r: (r["scenario"], r["name"]))
    return runs


def parse_ts(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def run_label(run):
    start = parse_ts(run["data"].get("events", {}).get("started"))
    return start.astimezone().strftime("%m-%d %H:%M:%S") if start else run["name"]


def dig(data, *path, default="TBD"):
    for key in path:
        if not isinstance(data, dict) or key not in data:
            return default
        data = data[key]
    return default if data is None or data == "" else data


# ── rendering: a view is a list of (text, style) lines ─────────────────────────
# style: "h" heading, "d" dim, "ok" good, "warn" bad, "" normal

def bar(value, maximum):
    try:
        n = int(round(BAR * float(value) / float(maximum))) if float(maximum) > 0 else 0
    except (TypeError, ValueError):
        return ""
    return "█" * max(0, min(BAR, n))


def table(rows, headers):
    """Left-aligned text table; rows are lists of strings."""
    cells = [[str(c) for c in headers]] + [[str(c) for c in r] for r in rows]
    widths = [max(len(r[i]) for r in cells) for i in range(len(headers))]
    out = [("  ".join(c.ljust(w) for c, w in zip(cells[0], widths)), "h")]
    for r in cells[1:]:
        out.append(("  ".join(c.ljust(w) for c, w in zip(r, widths)), ""))
    return out


def offset(events, key):
    t0, t = parse_ts(events.get("started")), parse_ts(events.get(key))
    return "+%ds" % int((t - t0).total_seconds()) if t0 and t else "?"


def timeline(events):
    lines = [("Timeline", "h")]
    for key, value in sorted(events.items(), key=lambda kv: kv[1]):
        lines.append(("  %-9s %-24s %s" % (offset(events, key), key, value), "d"))
    return lines


def header(run):
    d = run["data"]
    c = d.get("cluster", {})
    started = parse_ts(dig(d, "events", "started"))
    ended = parse_ts(dig(d, "events", "ended"))
    took = "%ds" % int((ended - started).total_seconds()) if started and ended else "?"
    mem = c.get("worker_memory", "")
    try:
        mem = "%.1f GiB" % (int(mem.rstrip("Ki")) / 1024 / 1024)
    except ValueError:
        pass
    return [
        ("%s  %s" % (run["scenario"], run_label(run)), "h"),
        ("Kubernetes %s, worker %s CPUs, %s memory, took %s" %
         (c.get("kubernetes", "?"), c.get("worker_cpus", "?"), mem or "?", took), "d"),
        ("", ""),
    ]


def view_pattern(run):
    d, e = run["data"], run["data"].get("events", {})
    ready = parse_ts(e.get("ready"))
    req = parse_ts(e.get("resize_requested"))
    done = parse_ts(e.get("resize_done"))
    gap = lambda a, b: "%ds" % int((b - a).total_seconds()) if a and b else "?"
    lines = [
        ("CPU                %s  ->  %s" % (dig(d, "cpu_start"), dig(d, "cpu_end")), ""),
        ("cpu.max after     %s" % dig(d, "cpu_max_after"), ""),
        ("Restarts          %s" % dig(d, "restart_count"),
         "ok" if dig(d, "restart_count") == 0 else "warn"),
        ("Ready -> resize requested   %s" % gap(ready, req), ""),
        ("Resize requested -> done    %s" % gap(req, done), ""),
        ("", ""),
    ]
    if "rollout" in d:
        r = d["rollout"]
        kept = r.get("boost_kept")
        lines += [
            ("After kubectl rollout restart", "h"),
            ("  initial CPU request   %s" % dig(r, "initial_cpu_request"), ""),
            ("  Spring startup        %ss" % dig(r, "spring_startup_s"), ""),
            ("  boost kept            %s" % kept, "ok" if kept else "warn"),
            ("", ""),
        ]
    return lines + timeline(e)


def view_manual(run):
    d = run["data"]
    rows = [["cpu.max", dig(d, "before", "cpu_max"), dig(d, "after", "cpu_max")],
            ["CPU request", dig(d, "before", "cpu_request"), dig(d, "after", "cpu_request")],
            ["CPU limit", dig(d, "before", "cpu_limit"), dig(d, "after", "cpu_limit")]]
    return table(rows, ["", "before", "after"]) + [
        ("", ""),
        ("restartCount  %s" % dig(d, "restart_count"), "ok" if dig(d, "restart_count") == 0 else "warn"),
        ("", ""),
    ] + timeline(d.get("events", {}))


def view_compare(run):
    d = run["data"]
    v = d.get("variants", {})
    names = [n for n in ("steady", "peak", "boost") if n in v]
    rows = [[n, dig(v[n], "ready_seconds"), dig(v[n], "spring_startup_seconds"),
             dig(v[n], "nr_throttled_at_ready"), dig(v[n], "throttled_usec_at_ready"),
             dig(v[n], "cpu_request_after_hold"), dig(v[n], "restart_count")] for n in names]
    lines = [("mode: %s" % dig(d, "mode"), "d"), ("", "")]
    lines += table(rows, ["variant", "Ready s", "Spring s", "nr_throttled", "throttled_usec",
                          "CPU request after hold", "restarts"])
    lines += [("", ""), ("Time to Ready (s)", "h")]
    top = max([float(dig(v[n], "ready_seconds", default=0)) for n in names] or [1])
    for n in names:
        lines.append(("  %-7s %-*s %s" % (n, BAR, bar(dig(v[n], "ready_seconds", default=0), top),
                                         dig(v[n], "ready_seconds")), ""))
    lines += [("", ""), ("Throttled time at Ready (s)", "h")]
    secs = {n: float(dig(v[n], "throttled_usec_at_ready", default=0)) / 1e6 for n in names}
    top = max(list(secs.values()) or [1])
    for n in names:
        lines.append(("  %-7s %-*s %.1f" % (n, BAR, bar(secs[n], top), secs[n]), ""))
    return lines + [("", "")] + timeline(d.get("events", {}))


def view_stabilization(run):
    d = run["data"]
    runs = d.get("runs", {})
    keys = [k for k in ("a_0s", "b_30s") if k in runs]
    rows = [[k, dig(runs[k], "stabilization_seconds"), dig(runs[k], "throttle", "ratio_after"),
             dig(runs[k], "k6_window", "p50_ms"), dig(runs[k], "k6_window", "p95_ms"),
             dig(runs[k], "k6_window", "requests"), dig(runs[k], "restart_count")] for k in keys]
    lines = [("120 s after the resize, load from Ready (VUs: %s)" % dig(d, "load", "vus"), "d"), ("", "")]
    lines += table(rows, ["run", "stabilizationSeconds", "throttle ratio", "p50 ms", "p95 ms",
                          "requests", "restarts"])
    lines += [("", ""), ("Throttle ratio", "h")]
    for k in keys:
        r = dig(runs[k], "throttle", "ratio_after", default=0)
        lines.append(("  %-5s %-*s %s" % (k, BAR, bar(r, 1), r), ""))
    lines += [("", ""), ("k6 p95 (ms)", "h")]
    top = max([float(dig(runs[k], "k6_window", "p95_ms", default=0)) for k in keys] or [1])
    for k in keys:
        p = dig(runs[k], "k6_window", "p95_ms", default=0)
        lines.append(("  %-5s %-*s %s" % (k, BAR, bar(p, top), p), ""))
    lines += [("", ""), ("Grafana window (same scale for both runs)", "h")]
    for k in keys:
        w = runs[k].get("window", {})
        lines.append(("  %-5s %s  to  %s" % (k, w.get("from", "?"), w.get("to", "?")), "d"))
    return lines + [("", "")] + timeline(d.get("events", {}))


def view_jvm(run):
    d = run["data"]
    v = d.get("variants", {})
    names = [n for n in ("default", "cpus1") if n in v]
    rows = [[n, dig(v[n], "detected_cpus_at_startup"), dig(v[n], "throttle", "ratio_during_load"),
             dig(v[n], "k6_window", "p50_ms"), dig(v[n], "k6_window", "p95_ms"),
             dig(v[n], "k6_window", "requests"), dig(v[n], "restart_count")] for n in names]
    lines = [("load: %s VUs, %s s" % (dig(d, "load", "vus"), dig(d, "load", "duration_seconds")), "d"), ("", "")]
    lines += table(rows, ["variant", "CPUs at startup", "throttle ratio", "p50 ms", "p95 ms",
                          "requests", "restarts"])
    lines += [("", ""), ("k6 p95 (ms)", "h")]
    top = max([float(dig(v[n], "k6_window", "p95_ms", default=0)) for n in names] or [1])
    for n in names:
        p = dig(v[n], "k6_window", "p95_ms", default=0)
        lines.append(("  %-8s %-*s %s" % (n, BAR, bar(p, top), p), ""))
    return lines + [("", "")] + timeline(d.get("events", {}))


def view_generic(run):
    lines = []

    def walk(prefix, node):
        if isinstance(node, dict):
            for k, val in node.items():
                walk(prefix + [k], val)
        else:
            lines.append(("%-40s %s" % (".".join(prefix), node), ""))
    walk([], run["data"])
    return lines


VIEWS = {"sidecar": view_pattern, "controller": view_pattern, "operator": view_pattern,
         "vpa": view_pattern, "manual-resize": view_manual, "compare": view_compare,
         "stabilization": view_stabilization, "jvm-cpus": view_jvm}


def render(run, raw=False):
    if raw:
        return [(l, "") for l in json.dumps(run["data"], indent=2).splitlines()]
    return header(run) + VIEWS.get(run["scenario"], view_generic)(run) + [("", ""), (run["name"], "d")]


# ── plain mode ─────────────────────────────────────────────────────────────────

def plain(directory):
    runs = load_runs(directory)
    if not runs:
        print("No results yet. Run a scenario first.")
        return
    latest = {}
    for r in runs:
        latest[r["scenario"]] = r
    for scenario in sorted(latest):
        for text, _ in render(latest[scenario]):
            print(text)
        print()


# ── curses ─────────────────────────────────────────────────────────────────────

def stamp(run):
    return run["name"][len(run["scenario"]) + 1:]


def list_order(runs):
    """Scenarios alphabetical, newest run first within a scenario."""
    by_time = sorted(range(len(runs)), key=lambda i: stamp(runs[i]), reverse=True)
    return sorted(by_time, key=lambda i: runs[i]["scenario"])


def run_tui(stdscr, directory):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_RED, -1)
    styles = {"h": curses.color_pair(1) | curses.A_BOLD, "ok": curses.color_pair(2),
              "warn": curses.color_pair(3) | curses.A_BOLD, "d": curses.A_DIM, "": 0}

    runs = load_runs(directory)
    sel = max(range(len(runs)), key=lambda i: stamp(runs[i])) if runs else 0
    scroll, raw = 0, False
    while True:
        h, w = stdscr.getmaxyx()
        left = min(36, max(24, w // 3))
        stdscr.erase()
        if not runs:
            stdscr.addstr(1, 2, ("No results in %s. Run a scenario first." % directory)[:w - 3])
        else:
            rows, last = [], None
            for i in list_order(runs):
                if runs[i]["scenario"] != last:
                    last = runs[i]["scenario"]
                    rows.append((None, last))
                rows.append((i, "  " + run_label(runs[i])))
            sel_row = next(n for n, (i, _) in enumerate(rows) if i == sel)
            top = max(0, sel_row - (h - 4))
            for n, (i, text) in enumerate(rows[top:top + h - 2]):
                text = text[:left - 2]
                if i is None:
                    stdscr.addstr(1 + n, 0, text, styles["h"])
                elif i == sel:
                    stdscr.addstr(1 + n, 0, text.ljust(left - 2), curses.A_REVERSE)
                else:
                    stdscr.addstr(1 + n, 0, text)
            for y in range(h - 1):
                stdscr.addstr(y, left - 1, "|")
            view = render(runs[sel], raw)
            scroll = max(0, min(scroll, max(0, len(view) - (h - 2))))
            for n, (text, style) in enumerate(view[scroll:scroll + h - 2]):
                stdscr.addstr(1 + n, left + 1, text[:max(0, w - left - 2)], styles.get(style, 0))
        foot = " j/k run   J/K scroll   t raw JSON   r reload   q quit"
        stdscr.addstr(h - 1, 0, foot[:w - 1].ljust(w - 1), curses.A_REVERSE)
        stdscr.refresh()

        key = stdscr.getch()
        if key in (ord("q"), 27):
            return
        if key == ord("r"):
            runs = load_runs(directory)
            sel = min(sel, max(0, len(runs) - 1))
        elif key == ord("t"):
            raw, scroll = not raw, 0
        elif runs and key in (curses.KEY_DOWN, ord("j"), curses.KEY_UP, ord("k")):
            order = list_order(runs)
            p = order.index(sel) + (1 if key in (curses.KEY_DOWN, ord("j")) else -1)
            sel, scroll = order[max(0, min(len(order) - 1, p))], 0
        elif key in (curses.KEY_NPAGE, ord("J")):
            scroll += max(1, h // 2)
        elif key in (curses.KEY_PPAGE, ord("K")):
            scroll = max(0, scroll - max(1, h // 2))


def main():
    args = [a for a in sys.argv[1:] if a != "--plain"]
    directory = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
    directory = os.path.abspath(directory)
    if "--plain" in sys.argv or not sys.stdout.isatty():
        plain(directory)
    else:
        curses.wrapper(run_tui, directory)


if __name__ == "__main__":
    main()
