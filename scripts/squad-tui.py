#!/usr/bin/env python3
"""
squad-tui.py — Live TUI dashboard for squad-devkit.
Reads .squad/messages.db (SQLite) and renders a flow-style orchestration view
inspired by the Claude Code subagent/swarm diagram.

Usage:
  python3 scripts/squad-tui.py [--db .squad/messages.db] [--interval 1.0] [--snapshot]
"""

import argparse
import curses
import datetime
import json
import re
import os
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def connect_db(db_path: str) -> Optional[sqlite3.Connection]:
    if not os.path.exists(db_path):
        return None
    conn = sqlite3.connect(f"{Path(db_path).resolve().as_uri()}?mode=rw", uri=True, timeout=1.0)
    conn.execute("PRAGMA query_only=ON")
    conn.row_factory = sqlite3.Row
    return conn


def read_manager_context(project_dir: Path) -> Optional[int]:
    try:
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(project_dir.resolve()))
        directory = Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser() / "projects" / slug
        transcript = max(directory.glob("*.jsonl"), key=lambda path: path.stat().st_mtime)
        with transcript.open("rb") as source:
            source.seek(0, os.SEEK_END)
            size = source.tell()
            source.seek(max(0, size - 256 * 1024))
            data = source.read().splitlines()
        if size > 256 * 1024:
            data = data[1:]
        for line in reversed(data):
            try:
                usage = json.loads(line).get("message", {}).get("usage")
                if isinstance(usage, dict):
                    return sum(int(usage.get(key, 0) or 0) for key in
                               ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            except (ValueError, TypeError, AttributeError):
                continue
    except (OSError, ValueError):
        pass
    return None


def run_details(run: Dict[str, Any]) -> None:
    try:
        details = json.loads(run.get("details") or "{}")
        if not isinstance(details, dict):
            details = {}
    except (ValueError, TypeError):
        details = {}
    fallback = {}
    try:
        with open(run.get("status_file") or "", encoding="utf-8") as source:
            fallback = dict(line.rstrip("\n").split("=", 1) for line in source if "=" in line)
    except (OSError, UnicodeError, ValueError):
        pass
    for key in ("role", "model", "model_tier", "started", "finished", "verify", "verify_exit", "report", "merged", "discarded", "scope_violation"):
        value = details.get(key) or fallback.get(key)
        run[key] = str(value) if isinstance(value, (str, int, float)) and value != "" else None


def result_line(run: Dict[str, Any]) -> str:
    try:
        with open(run.get("report") or "", "rb") as source:
            for line in source.read(4096).decode("utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line or line.startswith(("[", "squad-worker:")):
                    continue
                line = re.sub(r"^(?:(?:[-*] |\d+\. |\*\*|#+\s*)+)", "", line).strip()
                if line and not re.match(r"^(?:Plan|Verify|Base|Diff|Changed|Scope|Worktree|Review|Merge|Discard): ", line):
                    return line.removesuffix("**").rstrip()
    except OSError:
        pass
    return run.get("verdict") or "—"


def timestamp(value: Any) -> Optional[int]:
    try:
        return int(value) if value is not None and str(value).strip() else None
    except (TypeError, ValueError, OverflowError):
        return None


def events(state: Dict[str, Any]) -> List[Tuple[int, str, str, str]]:
    result = []
    for run in state["runs"]:
        who = run.get("worker_id") or run.get("run_name") or "?"
        started, finished = timestamp(run.get("started")), timestamp(run.get("finished"))
        if started is not None:
            result.append((started, who, "started", "run"))
        if finished is not None:
            failed = (run.get("state") or "").lower() in ("failed", "stopped", "lost", "error")
            result.append((finished, who, run.get("state") or "finished", "fail" if failed else "done"))
            if run.get("verify"):
                passed = str(run.get("verify_exit")) == "0"
                result.append((finished, who, "Verify: " + ("pass" if passed else "FAIL"), "verify ✓" if passed else "verify ✗"))
    for message in state["messages"]:
        ts = timestamp(message.get("created_at"))
        if ts is not None:
            result.append((ts, message.get("from_agent") or "?", f"→ {message.get('to_agent') or '?'}: {message.get('content') or ''}", "msg"))
    return sorted(result, key=lambda event: event[0])[-12:]


def fetch_state(db_path: str) -> Dict[str, Any]:
    state: Dict[str, Any] = {
        "exists": False,
        "agents": [],
        "runs": [],
        "review_runs": [],
        "tasks": [],
        "messages": [],
        "tokens_in": 0,
        "tokens_out": 0,
        "tokens_cached": 0,
        "manager_context": read_manager_context(Path(db_path).resolve().parent.parent),
    }
    conn = connect_db(db_path)
    if conn is None:
        return state

    state["exists"] = True
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, role, status, client_type, last_seen FROM agents "
            "WHERE archived_at IS NULL ORDER BY joined_at DESC LIMIT 20"
        )
        state["agents"] = [dict(r) for r in cur.fetchall()]

        cur.execute(
            "SELECT workspace, run_name, worker_id, engine, state, verdict, "
            "COALESCE(tokens_in, 0) AS tokens_in, COALESCE(tokens_out, 0) AS tokens_out, "
            "COALESCE(tokens_cached, 0) AS tokens_cached, worktree, status_mtime, status_file, details "
            "FROM worker_runs ORDER BY status_mtime DESC LIMIT 12"
        )
        state["runs"] = [dict(r) for r in cur.fetchall()]
        for run in state["runs"]:
            run_details(run)

        cur.execute(
            "SELECT workspace, run_name, worker_id, engine, state, verdict, "
            "COALESCE(tokens_in, 0) AS tokens_in, COALESCE(tokens_out, 0) AS tokens_out, "
            "COALESCE(tokens_cached, 0) AS tokens_cached, worktree, status_mtime, status_file, details "
            "FROM worker_runs WHERE worktree IS NOT NULL AND worktree != '' ORDER BY status_mtime DESC LIMIT 200"
        )
        state["review_runs"] = [dict(r) for r in cur.fetchall()]
        for run in state["review_runs"]:
            run_details(run)

        cur.execute(
            "SELECT COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0), COALESCE(SUM(tokens_cached), 0) FROM worker_runs"
        )
        row = cur.fetchone()
        if row:
            state["tokens_in"] = row[0] or 0
            state["tokens_out"] = row[1] or 0
            state["tokens_cached"] = row[2] or 0

        cur.execute(
            "SELECT id, title, status, assigned_to, updated_at FROM tasks "
            "ORDER BY updated_at DESC LIMIT 20"
        )
        state["tasks"] = [dict(r) for r in cur.fetchall()]

        cur.execute(
            "SELECT id, from_agent, to_agent, content, created_at FROM messages "
            "ORDER BY id DESC LIMIT 12"
        )
        state["messages"] = list(reversed([dict(r) for r in cur.fetchall()]))
    except sqlite3.Error as exc:
        state["error"] = str(exc)
    finally:
        conn.close()
    return state


def fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n // 1_000}k"
    return str(n)


def fmt_ts(ts: int) -> str:
    try:
        return datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S")
    except Exception:
        return "--:--:--"


def trunc(s: str, width: int) -> str:
    s = " ".join((s or "").split())
    if width <= 0:
        return ""
    if len(s) <= width:
        return s
    if width <= 1:
        return s[:width]
    return s[: width - 1] + "…"


def dashboard_lines(state: Dict[str, Any], db_path: str) -> List[Tuple[str, int]]:
    lines: List[Tuple[str, int]] = [("SQUAD-DEVKIT ORCHESTRATION", 0)]
    if not state["exists"]:
        return lines + [(f"Database not found: {db_path}", 2)]

    def section(title: str, rows: List[str], color: int) -> None:
        lines.append(("", 0))
        lines.append((title, color))
        lines.extend(("  " + row, color) for row in rows or ["(none recorded)"])

    agents = state["agents"]
    leaders = [a for a in agents if any(role in (a["role"] or "").lower() for role in ("manager", "advisor"))]
    section("MANAGER / ADVISOR", [f"{a['id']}  |  {a['role'] or 'unknown'}  |  {a['status'] or 'unknown'}  |  {a['client_type'] or 'unknown'}" for a in leaders], 1)
    section("TASKS", [f"{t['title'] or t['id']}  |  {t['status'] or 'unknown'}  |  {t['assigned_to'] or 'unassigned'}  |  {t['id']}" for t in state["tasks"]], 4)
    section("WORKTREES / WORKERS", [f"{r['run_name'] or r['worker_id']}  |  {r['state'] or 'unknown'}  |  {r['engine'] or 'unknown'}  |  {r['worktree'] or 'no worktree'}  |  verdict: {r['verdict'] or 'none'}  |  tokens: {fmt_tokens(r['tokens_in'])} in / {fmt_tokens(r['tokens_out'])} out" for r in state["runs"]], 3)
    others = [a for a in agents if a not in leaders]
    section("AGENTS", [f"{a['id']}  |  {a['role'] or 'unknown'}  |  {a['status'] or 'unknown'}  |  {a['client_type'] or 'unknown'}" for a in others], 3)
    section("SESSION LOG", [f"{fmt_ts(m['created_at'])}  {m['from_agent'] or '?'} → {m['to_agent'] or '?'}  {m['content'] or ''}" for m in state["messages"]], 5)
    if state.get("error"):
        lines.append((f"Database error: {state['error']}", 2))
    return lines


def render_snapshot(state: Dict[str, Any], width: int = 92, db_path: str = ".squad/messages.db") -> str:
    return "\n".join("".join(text for text, _ in row).rstrip() for row in dashboard_canvas(state, db_path, width))


def safe_add(stdscr: Any, y: int, x: int, text: str, attr: int = 0) -> None:
    height, width = stdscr.getmaxyx()
    if 0 <= y < height and 0 <= x < width - 1:
        try:
            stdscr.addstr(y, x, text[:width - x - 1], attr)
        except curses.error:
            pass


def dashboard_canvas(state: Dict[str, Any], db_path: str, width: int, frame: int = 0) -> List[List[Tuple[str, int]]]:
    width = max(4, width)
    agents, tasks, runs = state["agents"], state["tasks"], state["runs"]
    leaders = [a for a in agents if any(role in (a["role"] or "").lower() for role in ("manager", "advisor"))]
    others = [a for a in agents if a not in leaders]

    def status(value: Any) -> int:
        value = (value or "unknown").lower()
        if value in ("failed", "error", "blocked", "cancelled"):
            return 6
        if value in ("done", "completed", "success", "passed", "active", "running", "in_progress"):
            return 4
        return 2

    def review_rows(runs: List[Dict[str, Any]]) -> List[Tuple[str, int]]:
        rows = []
        seen = set()
        for run in runs:
            worker = run.get("worker_id")
            if worker in seen:
                continue
            seen.add(worker)
            state = run.get("state") or ""
            worktree = run.get("worktree")
            if (state.lower() not in ("completed", "failed") or not worktree or
                    not os.path.isdir(worktree) or run.get("merged") or run.get("discarded")):
                continue
            verify_exit = run.get("verify_exit")
            verify = "✓" if str(verify_exit) == "0" else "✗" if verify_exit else "—"
            scope = "violation" if run.get("scope_violation") and str(run["scope_violation"]) != "0" else "ok"
            rows.append((f"{worker} · {state} · verify {verify} · scope {scope}", status(state)))
        return rows[:4] + [(f"+{len(rows) - 4} more", 0)] if len(rows) > 4 else rows or [("nothing to review", 0)]

    def panel(title: str, rows: List[Tuple[str, int]], w: int) -> List[List[Tuple[str, int]]]:
        rows = rows or [("(none recorded)", 0)]
        top = "┌ " + trunc(title, w - 4) + " "
        result = [[(top + "─" * max(0, w - len(top) - 1) + "┐", 1)]]
        for text, color in rows:
            text = text if len(text) <= w - 4 else trunc(text, w - 4)
            result.append([("│ ", 1), (text, color), (" " * (w - 3 - len(text)) + "│", 1)])
        result.append([("└" + "─" * (w - 2) + "┘", 1)])
        return result

    def combine(panels: List[List[List[Tuple[str, int]]]], widths: List[int]) -> List[List[Tuple[str, int]]]:
        height = max(map(len, panels))
        return [sum((p[y] if y < len(p) else [(" " * w, 0)] for p, w in zip(panels, widths)), []) for y in range(height)]

    context = state.get("manager_context")
    tier_colors = {"fast": 3, "balanced": 2, "strong": 1, "manager": 1, "other": 5}
    header = [f"workers (all runs): {fmt_tokens(state['tokens_in'])} in · {fmt_tokens(state['tokens_cached'])} cached · {fmt_tokens(state['tokens_out'])} out",
              f"manager context: {fmt_tokens(context) if context is not None else 'n/a'} · kept out of manager: {fmt_tokens(state['tokens_in'] + state['tokens_out'])}"]
    canvas = [[(" SQUAD-DEVKIT ORCHESTRATION", 1)]]
    canvas += [[(trunc(line, width), 0)] for line in header]
    canvas += [[(f"■ {tier}" + ("  " if tier != "manager" else ""), tier_colors[tier]) for tier in ("fast", "balanced", "strong", "manager")]]
    if not state["exists"]:
        return canvas + panel("DATABASE", [(f"Database not found: {db_path}", 2)], width)
    leader_rows = []
    now = int(time.time())
    for a in leaders:
        idle = now - a['last_seen'] if a.get('last_seen') else 0
        duration = f"{idle // 60}m" if idle < 3600 else f"{idle // 3600}h{idle % 3600 // 60:02d}m" if idle < 86400 else f"{idle // 86400}d"
        label = f"{a['status'] or 'unknown'} · {a['client_type'] or 'unknown'}"
        if idle >= 300:
            label += f" · idle {duration}"
        leader_rows.extend([(f"{a['id']} · {a['role'] or 'unknown'}", 1), (label, status(a['status']))])
    task_rows = []
    for t in tasks:
        task_rows.extend([(f"{t['title'] or t['id']} ({t['id']})", 0), (f"{t['status'] or 'unknown'} · {t['assigned_to'] or 'unassigned'}", status(t['status']))])
    for r in runs:
        task_rows.append((f"{r['worker_id'] or r['run_name']}: {Path(r['worktree']).name if r['worktree'] else 'no worktree'}", 3))
    seen_workers = set()
    worker_rows = []
    for run in runs:
        if run.get("worker_id") not in seen_workers:
            seen_workers.add(run.get("worker_id"))
            worker_rows.append(run)
    worker_rows.sort(key=lambda r: (r["state"] or "").lower() not in ("running", "active", "in_progress"))

    def worker_panel(run: Dict[str, Any], w: int) -> List[List[Tuple[str, int]]]:
        value = (run.get("state") or "").lower()
        running = value in ("running", "active", "in_progress")
        done = value in ("done", "completed", "success", "passed")
        failed = value in ("failed", "error", "lost")
        stopped = value in ("stopped", "cancelled")
        label = "RUN" if running else "DONE" if done else "FAIL" if failed else "STOP" if stopped else "?"
        tier = tier_colors.get((run.get("model_tier") or "").lower(), tier_colors["other"])
        heading = f"{run.get('role') or 'unknown'} · {run.get('model') or run.get('engine') or 'unknown'} "
        heading = trunc(heading, max(0, w - 4 - len(label) - 3)) + " "
        available = max(0, w - 4)
        started = timestamp(run.get("started"))
        elapsed = max(0, int(time.time()) - started) if started is not None else 0
        clock = f" {elapsed // 60:02d}:{elapsed % 60:02d}" if running else ""
        bar_width = max(0, available - len(clock))
        if running:
            block = min(4, bar_width)
            start = frame % max(1, bar_width - block + 1)
            bar = "░" * start + "█" * block + "░" * (bar_width - start - block)
        else:
            bar = ("█" if done or failed or stopped else "░") * bar_width
        result = result_line(run)
        tokens = run['tokens_in'] + run['tokens_out']
        suffix = f" · {fmt_tokens(tokens)} tok" if tokens > 0 else " · tokens at turn end" if running else ""
        if tokens == 0 and (failed or stopped) and result == "—":
            result = "no model usage"
        if len(result) + len(suffix) <= available:
            result += suffix
        rows = panel(run.get('worker_id') or run.get('run_name') or 'unknown', [("", 0), (bar + clock, 4 if done else 6 if failed or stopped else tier), (result, 0)], w)
        tag = f"[{label}]"
        rows[1] = [("│ ", 1), (heading, tier), (tag, 6 if failed or stopped else tier), (" " * max(0, w - 3 - len(heading) - len(tag)) + "│", 1)]
        return rows
    preview, remaining = task_rows[:4], task_rows[4:]
    if width >= 90:
        left = max(22, width // 5, min(width // 3, max((len(text) + 4 for text, _ in leader_rows if " · idle " in text), default=0)))
        flow_width = width - left
        center = flow_width // 2
        def centered(title: str, rows: List[Tuple[str, int]]) -> List[List[Tuple[str, int]]]:
            w = max(24, flow_width * 2 // 3)
            padding = (flow_width - w) // 2
            return [[(" " * padding, 0)] + row + [(" " * (flow_width - w - padding), 0)] for row in panel(title, rows, w)]
        flow = centered("MANAGER", [(a['id'], 1) for a in leaders if 'manager' in (a['role'] or '').lower()])
        def stem(moving: bool = False) -> None:
            for row in range(2 if moving else 1):
                flow.append([(" " * center + ("●" if moving and frame % 2 == row else "│"), 3)])
        stem()
        flow.extend(centered("TASK & WORKTREE LAYER", preview))
        columns = max(1, flow_width // 26)
        cards = worker_rows[:columns * 3]
        groups = [cards[i:i + columns] for i in range(0, len(cards), columns)]
        centered_active = bool(groups) and len(groups[0]) % 2 == 1 and (groups[0][len(groups[0]) // 2]["state"] or "").lower() in ("running", "active", "in_progress")
        stem(centered_active)
        if cards:
            def layout(group: List[Dict[str, Any]]) -> Tuple[List[int], List[int]]:
                widths = [flow_width // len(group)] * len(group)
                widths[-1] += flow_width - sum(widths)
                return widths, [sum(widths[:i]) + w // 2 for i, w in enumerate(widths)]
            def rail(branch: str, centers: List[int], group: List[Dict[str, Any]]) -> None:
                line = [' '] * flow_width
                for x in range(min(centers + [center]), max(centers + [center]) + 1):
                    line[x] = '─'
                for x in centers:
                    line[x] = '┬' if branch == 'down' else '┴'
                line[center] = '┴' if branch == 'down' else '┬'
                if branch == 'down':
                    for run, x in zip(group, centers):
                        active = (run['state'] or '').lower() in ('running', 'active', 'in_progress')
                        distance = abs(x - center)
                        if active and distance > 1:
                            line[center + (1 if x > center else -1) * (1 + frame % (distance - 1))] = '●'
                flow.append([(''.join(line), 3)])
            widths, centers = layout(groups[0])
            rail('down', centers, groups[0])
            for i, group in enumerate(groups):
                if i:
                    stem()
                widths, centers = layout(group)
                flow.extend(combine([worker_panel(run, w) for run, w in zip(group, widths)], widths))
            rail('up', centers, groups[-1])
            if len(worker_rows) > len(cards):
                flow.append([(f"+{len(worker_rows) - len(cards)} more workers".center(flow_width), 0)])
        else:
            flow.extend(panel("WORKERS", [], flow_width))
        stem()
        flow.extend(centered("MANAGER REVIEW", review_rows(state.get("review_runs") or runs)))
        side = panel("MANAGER / ADVISOR", leader_rows, left)
        side[-1:-1] = [[("│" + " " * (left - 2) + "│", 1)] for _ in range(max(0, len(flow) - len(side)))]
        canvas += combine([side, flow], [left, flow_width])
        worker_rows = []
    else:
        canvas += panel("MANAGER / ADVISOR", leader_rows, width)
        canvas += panel("TASKS & WORKTREES", preview, width)
    log = []
    for ts, who, message, tag in events(state):
        content = f"{fmt_ts(ts)}  {who}  {message}"
        room = max(0, width - 4 - len(tag) - 1)
        content = trunc(content, room)
        log.append((content + " " * max(1, room + 1 - len(content)) + tag, 5))
    if state.get("error"):
        log.append((f"Database error: {state['error']}", 6))
    canvas += panel("SESSION LOG", log, width)
    run_ids = {run.get("worker_id") for run in runs}
    joined = [agent for agent in others if agent["id"] not in run_ids]
    if worker_rows or joined:
        canvas.append([(" WORKERS", 3)])
        worker_rows += joined
        columns = min(len(worker_rows), max(1, width // 26))
        for i in range(0, len(worker_rows), columns):
            group = worker_rows[i:i + columns]
            widths = [width // columns] * len(group)
            panels = []
            for item, w in zip(group, widths):
                if item in joined:
                    panels.append(panel(item["id"], [(f"{item['role'] or 'unknown'} · {item['client_type'] or 'unknown'} [{item['status'] or 'unknown'}]", tier_colors["other"]), ("░" * max(0, w - 4), tier_colors["other"]), ("joined agent", 0)], w))
                else:
                    panels.append(worker_panel(item, w))
            for row in combine(panels, widths):
                canvas.append(row + [(" " * (width - sum(widths)), 0)])
    elif width < 90:
        canvas += panel("WORKERS", [], width)
    if remaining:
        canvas += panel("MORE TASKS & WORKTREES", remaining, width)
    return canvas


def draw_tui(stdscr: Any, state: Dict[str, Any], db_path: str, offset: int, frame: int = 0) -> int:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    lines = dashboard_canvas(state, db_path, max(4, width - 1), frame)
    visible = max(0, height - 1)
    offset = min(max(0, offset), max(0, len(lines) - visible))
    for y, row in enumerate(lines[offset:offset + visible]):
        x = 0
        for text, color in row:
            attr = curses.color_pair(color) if color and curses.has_colors() else 0
            safe_add(stdscr, y, x, text, attr)
            x += len(text)
    safe_add(stdscr, height - 1, 0, f"q: quit  r: refresh  ↑/↓: scroll  {offset + 1}-{min(offset + visible, len(lines))}/{len(lines)}")
    stdscr.refresh()
    return offset


def manager_alive(pid: int) -> bool:
    if not pid:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def run_curses(stdscr: Any, db_path: str, interval: float) -> None:
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    stdscr.keypad(True)
    stdscr.nodelay(True)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        for pair, color in enumerate((curses.COLOR_MAGENTA, curses.COLOR_YELLOW, curses.COLOR_CYAN, curses.COLOR_GREEN, curses.COLOR_WHITE, curses.COLOR_RED), 1):
            curses.init_pair(pair, color, -1)
    manager = os.environ.get("SQUAD_DEVKIT_MANAGER_WRAPPER_PID", "")
    if manager and (not manager.isascii() or not manager.isdigit() or int(manager) <= 0):
        raise ValueError("invalid manager wrapper PID")
    manager_pid = int(manager) if manager else 0
    ready = os.environ.get("SQUAD_WORKER_MONITOR_READY")
    state = fetch_state(db_path)
    offset = 0
    last_fetch = time.monotonic()
    last_frame = int(last_fetch * 4)
    if not manager_alive(manager_pid):
        return
    offset = draw_tui(stdscr, state, db_path, offset)
    if ready:
        with open(ready, "w", encoding="utf-8") as marker:
            marker.write(f"{os.getpid()}\n")
    while manager_alive(manager_pid):
        ch = stdscr.getch()
        if ch in (ord("q"), ord("Q"), 27):
            break
        redraw = False
        if ch in (ord("r"), ord("R")) or time.monotonic() - last_fetch >= interval:
            state = fetch_state(db_path)
            last_fetch = time.monotonic()
            redraw = True
        if ch in (curses.KEY_DOWN, ord("j")):
            offset += 1
            redraw = True
        elif ch in (curses.KEY_UP, ord("k")):
            offset -= 1
            redraw = True
        elif ch == curses.KEY_RESIZE:
            redraw = True
        frame = int(time.monotonic() * 4)
        if frame != last_frame and any((r['state'] or '').lower() in ('running', 'active', 'in_progress') for r in state['runs']):
            redraw = True
        last_frame = frame
        if redraw:
            offset = draw_tui(stdscr, state, db_path, offset, frame)
        time.sleep(0.05)


def main() -> int:
    parser = argparse.ArgumentParser(description="Live TUI dashboard for squad-devkit")
    parser.add_argument("--db", default=".squad/messages.db", help="Path to messages.db")
    parser.add_argument("--interval", type=float, default=1.0, help="Refresh interval in seconds")
    parser.add_argument("--snapshot", action="store_true", help="Print a single text snapshot and exit")
    args = parser.parse_args()

    if args.interval <= 0:
        parser.error("--interval must be positive")

    if args.snapshot:
        state = fetch_state(args.db)
        print(render_snapshot(state, width=max(92, len(args.db) + 28), db_path=args.db))
        return 0

    curses.wrapper(run_curses, args.db, args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
