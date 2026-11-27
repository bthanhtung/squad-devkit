#!/usr/bin/env python3
import fcntl
import importlib.util
import json
import re
import os
import pty
import select
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/squad-tui.py'


def wait_for(check, process, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if check():
            return
        if process.poll() is not None:
            raise AssertionError(f'TUI exited early: {process.returncode}')
        time.sleep(0.05)
    raise AssertionError('timed out waiting for TUI')


def main():
    with tempfile.TemporaryDirectory() as directory:
        db = Path(directory) / '.squad' / 'messages #?.db'
        db.parent.mkdir()
        config = Path(directory) / 'claude'
        os.environ['CLAUDE_CONFIG_DIR'] = str(config)
        slug = re.sub(r'[^A-Za-z0-9]', '-', str(Path(directory).resolve()))
        transcript = config / 'projects' / slug / 'x.jsonl'
        transcript.parent.mkdir(parents=True)
        transcript.write_text('malformed\n' + json.dumps({'message': {'usage': {'input_tokens': 40000, 'cache_read_input_tokens': 7000, 'cache_creation_input_tokens': 1000}}}) + '\n')
        report = Path(directory) / 'report'
        report.write_text('squad-worker: metadata\n[dev-tui · codex] report: path\nWorktree: path\nPlan: ignored\nVerify: ignored\nBase: hash\nDiff: path\nChanged: files\nScope: ok\nReview: ok\nMerge: no\nDiscard: no\n- **Implemented feature**\n')
        status = Path(directory) / 'worker.status'
        status.write_text(f'role=developer\nmodel_tier=balanced\nreport={report}\nverify=check\nverify_exit=0\nfinished=4\n')
        ready = Path(directory) / 'ready'
        missing = subprocess.check_output([sys.executable, str(SCRIPT), '--db', str(db), '--snapshot'], text=True)
        assert str(db) in missing
        with sqlite3.connect(db) as conn:
            conn.executescript('''
                CREATE TABLE agents(id, role, status, client_type, last_seen, archived_at, joined_at);
                CREATE TABLE worker_runs(workspace, run_name, worker_id, engine, state, verdict, tokens_in, tokens_cached, tokens_out, worktree, status_mtime, status_file, details);
                CREATE TABLE tasks(id, title, status, assigned_to, updated_at);
                CREATE TABLE messages(id, from_agent, to_agent, content, created_at);
                INSERT INTO agents VALUES ('manager-2', 'manager', 'active', 'codex', 0, NULL, 1);
                INSERT INTO agents VALUES ('joined', 'developer', 'active', 'codex', 0, NULL, 2);
                INSERT INTO agents VALUES ('worker-one', 'developer', 'active', 'codex', 0, NULL, 3);
                INSERT INTO worker_runs VALUES ('ws', 'worker-one', 'worker-one', 'codex', 'running', NULL, 12, 4, 5, '/tmp/tree', 1, '', '{"role":"developer","model":"gpt","model_tier":"fast","started":"2"}');
                INSERT INTO worker_runs VALUES ('ws', 'worker-two', 'worker-two', 'claude', 'failed', 'fail', 8, 2, 3, '/tmp/tree-two', 2, '', '{"started":"1","finished":"3","verify":"check","verify_exit":"1"}');
                INSERT INTO worker_runs VALUES ('ws', 'worker-three', 'worker-three', 'codex', 'done', 'pass', 1, 1, 1, '/tmp/tree-three', 3, '', '{}');
                INSERT INTO tasks VALUES ('task-1', 'Build feature', 'in_progress', 'worker-one', 1);
                INSERT INTO messages VALUES (1, 'manager-2', 'worker-one', 'hello worker', 1);
            ''')
        with sqlite3.connect(db) as conn:
            conn.execute("UPDATE worker_runs SET status_file=? WHERE worker_id='worker-three'", (str(status),))
            conn.commit()
            assert conn.execute('PRAGMA journal_mode=WAL').fetchone()[0] == 'wal'
        assert not Path(str(db) + '-wal').exists()
        snapshot = subprocess.check_output([sys.executable, str(SCRIPT), '--db', str(db), '--snapshot'], text=True)
        for value in ('manager-2', 'Build feature', 'worker-one', 'hello worker', '48k', 'kept out of manager: 30', '■ fast', 'verify ✗', 'verify ✓', 'Implemented feature'):
            assert value in snapshot, value
        spec = importlib.util.spec_from_file_location('squad_tui', SCRIPT)
        tui = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tui)
        state = tui.fetch_state(str(db))
        conn = tui.connect_db(str(db))
        try:
            assert conn.execute('PRAGMA query_only').fetchone()[0] == 1
            try:
                conn.execute("DELETE FROM tasks")
                assert False, 'query_only must reject writes'
            except sqlite3.OperationalError:
                pass
        finally:
            conn.close()
        def lines(canvas):
            return ["".join(text for text, _ in row) for row in canvas]
        assert 'nothing to review' in '\n'.join(lines(tui.dashboard_canvas(state, str(db), 120, 0)))
        pending = dict(state['runs'][0], worker_id='review-worker', state='COMPLETED', worktree=directory,
                       verify_exit='0', scope_violation='0', merged=None, discarded=None)
        def review_text(runs):
            return '\n'.join(lines(tui.dashboard_canvas(dict(state, runs=runs, review_runs=[]), str(db), 160, 0)))
        assert 'review-worker · COMPLETED · verify ✓ · scope ok' in review_text([pending])
        separate = dict(state, review_runs=[pending])
        assert 'review-worker · COMPLETED · verify ✓ · scope ok' in '\n'.join(lines(tui.dashboard_canvas(separate, str(db), 160, 0)))
        with sqlite3.connect(db) as conn:
            conn.execute("INSERT INTO worker_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                         ('ws', 'old-review', 'old-review', 'codex', 'completed', 'pass', 0, 0, 0, directory, -1, str(status), '{}'))
            for i in range(12):
                conn.execute("INSERT INTO worker_runs VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                             ('ws', f'new-{i}', f'new-{i}', 'codex', 'running', None, 0, 0, 0, '', 10 + i, '', '{}'))
        loaded = tui.fetch_state(str(db))
        assert all(r['worker_id'] != 'old-review' for r in loaded['runs'])
        assert next(r for r in loaded['review_runs'] if r['worker_id'] == 'old-review')['verify_exit'] == '0'
        assert 'old-review · completed · verify ✓ · scope ok' in '\n'.join(lines(tui.dashboard_canvas(loaded, str(db), 160, 0)))
        assert 'nothing to review' in review_text([dict(pending, merged='yes')])
        assert 'nothing to review' in review_text([dict(pending, discarded='yes')])
        assert 'nothing to review' in review_text([dict(pending, worktree=str(Path(directory) / 'missing'))])
        assert 'nothing to review' in review_text([dict(pending, state='running'), pending])
        assert 'verify ✗ · scope violation' in review_text([dict(pending, verify_exit='1', scope_violation='1')])
        assert 'verify — · scope ok' in review_text([dict(pending, verify_exit=None)])
        reviews = review_text([dict(pending, worker_id=f'review-{i}') for i in range(6)])
        assert all(f'review-{i} · COMPLETED' in reviews for i in range(4))
        assert 'review-4 · COMPLETED' not in reviews and '+2 more' in reviews
        status.write_text('merged=yes\ndiscarded=yes\nscope_violation=1\n')
        detail = {'status_file': str(status)}
        tui.run_details(detail)
        assert (detail['merged'], detail['discarded'], detail['scope_violation']) == ('yes', 'yes', '1')
        wide_canvas = tui.dashboard_canvas(state, str(db), 120, 0)
        wide = lines(wide_canvas)
        assert wide[1] == 'workers (all runs): 21 in · 7 cached · 9 out'
        assert wide[2] == 'manager context: 48k · kept out of manager: 30'
        assert [color for _, color in wide_canvas[3]] == [3, 2, 1, 1]
        assert next(color for row in wide_canvas for text, color in row if 'developer · gpt ' in text) == wide_canvas[3][0][1]
        assert next(color for row in wide_canvas for text, color in row if text.startswith('manager-2 · manager')) == wide_canvas[3][3][1]
        assert 'developer · codex [active]' in '\n'.join(wide) and 'joined agent' in '\n'.join(wide)
        assert sum('┌ worker-one' in row for row in wide) == 1
        assert tui.result_line({'report': str(report)}) == 'Implemented feature'
        next_frame = lines(tui.dashboard_canvas(state, str(db), 120, 1))
        narrow = lines(tui.dashboard_canvas(state, str(db), 45, 0))
        assert narrow[1] == tui.trunc(wide[1], 45) and narrow[2] == tui.trunc(wide[2], 45)
        def position(canvas, text):
            return next((y, row.index(text)) for y, row in enumerate(canvas) if text in row)
        assert position(wide, 'MANAGER / ADVISOR')[1] < position(wide, '┌ MANAGER ─')[1]
        assert position(wide, '┌ MANAGER ─')[0] < position(wide, 'TASK & WORKTREE LAYER')[0] < position(wide, 'worker-one')[0]
        assert position(wide, 'worker-one')[0] < position(wide, 'MANAGER REVIEW')[0] < position(wide, 'SESSION LOG')[0]
        assert any('┬' in row for row in wide) and any('┴' in row for row in wide)
        assert position(wide, '┌ worker-one')[0] == position(wide, '┌ worker-two')[0] == position(wide, '┌ worker-three')[0]
        assert state['tokens_cached'] == 7 and state['manager_context'] == 48000
        broken = {'details': '{broken', 'status_file': str(Path(directory) / 'missing')}
        tui.run_details(broken)
        assert broken['role'] is None and tui.result_line(broken) == '—'
        assert tui.read_manager_context(Path(directory) / 'missing') is None
        assert next(r for r in state['runs'] if r['worker_id'] == 'worker-three')['role'] == 'developer'
        assert 'developer · gpt [RUN]' in '\n'.join(wide)
        assert any('█' in row for row in wide)
        zero_tokens = dict(state, runs=[dict(state['runs'][1], tokens_in=0, tokens_out=0, state='failed', verdict=None, report=None)])
        zero_card = '\n'.join(lines(tui.dashboard_canvas(zero_tokens, str(db), 120, 0)))
        assert 'no model usage' in zero_card and '0 tok' not in zero_card
        running_card = '\n'.join(lines(tui.dashboard_canvas(dict(state, runs=[dict(state['runs'][0], tokens_in=0, tokens_out=0, state='running', verdict=None, report=None)]), str(db), 160, 0)))
        assert 'tokens at turn end' in running_card
        token_card = '\n'.join(lines(tui.dashboard_canvas(dict(state, runs=[dict(state['runs'][0], tokens_in=45000, tokens_out=0)]), str(db), 160, 0)))
        assert '45k tok' in token_card
        assert [event[0] for event in tui.events(state)] == sorted(event[0] for event in tui.events(state))
        assert all(row.index('│', 1) == 119 for row in wide if 'verify ✓' in row or 'verify ✗' in row)
        assert wide != next_frame and sum(row.count('●') for row in wide) > 0
        actual = lines(tui.dashboard_canvas(state, str(db), 97, 0))
        assert position(actual, 'TASK & WORKTREE LAYER')[0] < position(actual, 'SESSION LOG')[0] < 45
        assert position(actual, 'hello worker')[0] < 45
        single = dict(state, runs=[next(r for r in state['runs'] if r['state'] == 'running')])
        single_frames = [lines(tui.dashboard_canvas(single, str(db), 97, frame)) for frame in range(2)]
        assert single_frames[0] != single_frames[1]
        assert all(sum(row.count('●') for row in frame) == 1 for frame in single_frames)
        assert position(actual, '┌ worker-one')[0] == position(actual, '┌ worker-three')[0]
        assert position(actual, '┌ worker-two')[0] < position(actual, 'MANAGER REVIEW')[0]
        runs = [dict(state['runs'][0], worker_id=f'graph-{i}', state='running') for i in range(11)]
        graph = lines(tui.dashboard_canvas(dict(state, runs=runs[:7] + [dict(runs[0], state='done')]), str(db), 120, 0))
        assert sum('┌ graph-0' in row for row in graph) == 1
        assert position(graph, '┌ graph-0')[0] == position(graph, '┌ graph-2')[0]
        assert position(graph, '┌ graph-3')[0] > position(graph, '┌ graph-0')[0]
        assert position(graph, '┌ graph-6')[0] < position(graph, 'MANAGER REVIEW')[0]
        overflow = lines(tui.dashboard_canvas(dict(state, runs=runs), str(db), 120, 0))
        assert '+2 more workers' in '\n'.join(overflow)
        assert '┌ graph-9' not in '\n'.join(overflow)
        now = int(time.time())
        leaders = [dict(state['agents'][0], id='idle-leader', role='manager', last_seen=now - 3900),
                   dict(state['agents'][0], id='active-leader', role='advisor', last_seen=now - 60)]
        leader_canvas = lines(tui.dashboard_canvas(dict(state, agents=leaders), str(db), 140, 0))
        assert 'idle 1h05m' in '\n'.join(leader_canvas)
        assert sum('idle ' in row for row in leader_canvas) == 1
        idle_row = next(row for row in leader_canvas if 'idle ' in row)
        assert '…' not in idle_row
        extra = dict(state, runs=state['runs'] + [dict(state['runs'][0], worker_id='worker-four')])
        larger = lines(tui.dashboard_canvas(extra, str(db), 160, 0))
        assert position(larger, '┌ worker-four')[0] == position(larger, '┌ worker-one')[0]
        idle = dict(state, runs=[dict(r, state='done') for r in state['runs']])
        assert lines(tui.dashboard_canvas(idle, str(db), 120, 0)) == lines(tui.dashboard_canvas(idle, str(db), 120, 1))
        grid = lines(tui.dashboard_canvas(extra, str(db), 80, 0))
        row = next(row for row in grid if '┌ worker-four' in row)
        assert len(row) == 80 and row.index('┐') == 25 and row.endswith(' ' * 28)
        assert position(narrow, 'MANAGER / ADVISOR')[0] < position(narrow, 'TASKS & WORKTREES')[0]
        assert position(narrow, 'SESSION LOG')[0] < position(narrow, '┌ worker-one')[0] < position(narrow, '┌ worker-two')[0]
        busy = dict(state, tasks=[dict(state['tasks'][0], id=f'task-{i}', title=f'Task {i}') for i in range(162)])
        for width in (45, 120):
            canvas = lines(tui.dashboard_canvas(busy, str(db), width, 0))
            assert position(canvas, 'worker-one')[0] < 20
            assert position(canvas, 'SESSION LOG')[0] < position(canvas, 'Task 161')[0]
        manager = subprocess.Popen(['sleep', '30'])
        master, slave = pty.openpty()
        process = None
        output = bytearray()
        def drain():
            while select.select([master], [], [], 0)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
            env = dict(os.environ, TERM='xterm-256color', SQUAD_WORKER_MONITOR_READY=str(ready), SQUAD_DEVKIT_MANAGER_WRAPPER_PID=str(manager.pid))
            process = subprocess.Popen([sys.executable, str(SCRIPT), '--db', str(db), '--interval', '0.1'], stdin=slave, stdout=slave, stderr=slave, env=env)
            wait_for(lambda: (drain() or ready.exists()), process)
            drain()
            assert int(ready.read_text()) == process.pid
            assert b'SQUAD-DEVKIT' in output
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 45, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            time.sleep(0.2)
            drain()
            output.clear()
            os.write(master, b'\x1bOB')
            def scrolled():
                drain()
                return b'2-' in output
            wait_for(scrolled, process)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 120, 0, 0))
            os.kill(process.pid, signal.SIGWINCH)
            with sqlite3.connect(db) as conn:
                conn.execute("UPDATE tasks SET title='Updated feature'")
            def updated():
                drain()
                return b'Updated feature' in output
            wait_for(updated, process)
            os.write(master, b'q')
            wait_for(lambda: (drain() or process.poll() is not None), process)
            assert process.returncode == 0
            ready.unlink()
            process = subprocess.Popen([sys.executable, str(SCRIPT), '--db', str(db)], stdin=slave, stdout=slave, stderr=slave, env=env)
            wait_for(lambda: (drain() or ready.exists()), process)
            manager.terminate()
            manager.wait(timeout=5)
            wait_for(lambda: (drain() or process.poll() is not None), process)
            assert process.returncode == 0
        finally:
            if process and process.poll() is None:
                process.kill()
                process.wait()
            if manager.poll() is None:
                manager.kill()
                manager.wait()
            os.close(master)
            os.close(slave)
    print('squad TUI smoke: OK')


if __name__ == '__main__':
    main()
