#!/usr/bin/env python3
"""Bash 3.2 input deadlines, complete-frame selection, and reload invalidation."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
END = b'\x1b[?2026l'


class View:
    def __init__(self, workspace, layout='graph'):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
        env = {k: v for k, v in os.environ.items() if not k.startswith('SQUAD_')}
        env.update(SQUAD_ORCHESTRATION_HOLD='0', SQUAD_ORCHESTRATION_INTERVAL='1',
                   PATH=str(workspace / 'bin') + os.pathsep + env['PATH'])
        self.proc = subprocess.Popen(
            ['/bin/bash', str(ROOT / 'scripts/squad-orchestration.sh'),
             '--layout', layout, str(workspace / '.squad/workers')],
            stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        self.pending = b''
        self.last = b''
        self.frame(lambda f: b'> dev-0 ' in f if layout == 'graph' else b'dev-0 ' in f, 10)

    def frame(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while True:
            while END in self.pending:
                frame, self.pending = self.pending.split(END, 1)
                self.last = frame
                if predicate(frame):
                    return frame
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.master], [], [], remaining)[0]:
                raise AssertionError(f'frame deadline {timeout}s; last={self.last[-500:]!r}')
            data = os.read(self.master, 65536)
            assert data, 'view exited before frame'
            self.pending += data

    def key(self, data, text, timeout):
        # Discard only bytes produced before this input; assertions use a complete new frame.
        while select.select([self.master], [], [], 0)[0]:
            self.pending += os.read(self.master, 65536)
        self.pending = b''
        started = time.monotonic()
        os.write(self.master, data)
        frame = self.frame(lambda f: text in f, timeout)
        elapsed = time.monotonic() - started
        assert elapsed <= timeout, (data, elapsed, timeout)
        print(f'{data!r}: {elapsed * 1000:.0f} ms (limit {timeout * 1000:.0f})')
        return frame

    def quit(self):
        started = time.monotonic()
        os.write(self.master, b'q')
        self.proc.wait(timeout=.3)
        assert self.proc.returncode == 0
        elapsed = time.monotonic() - started
        assert elapsed <= .3
        print(f'quit: {elapsed * 1000:.0f} ms (limit 300)')

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=5)
        os.close(self.master)


def status(workspace, n):
    path = workspace / f'.squad/workers/dev-{n:02d}.status'
    path.write_text(f'worker=dev-{n}\nstarted={100+n}\nstate=completed\nrole=dev\nmodel=fixture-{n}\n')
    return path


def fixture(workspace, count=12):
    (workspace / '.squad/workers').mkdir(parents=True)
    (workspace / 'bin').mkdir()
    for n in range(count):
        status(workspace, n)
    (workspace / '.squad/messages.db').write_text('0')
    (workspace / 'history').write_text('[2026-11-20T00:00:00Z] manager -> dev-0: brief AAA\n')
    # Exercise the production database stat gate, not the HISTORY_CMD override.
    squad = workspace / 'bin/squad'
    squad.write_text('#!/bin/bash\n[[ "$1" == history ]] || exit 1\n'
                     'echo start >> history-start\nsleep 0.04\ncat history\n')
    squad.chmod(0o755)


def reload_start(view, workspace, previous):
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if select.select([view.master], [], [], .005)[0]:
            view.pending += os.read(view.master, 65536)
        count = len((workspace / 'history-start').read_text().splitlines())
        if count > previous:
            return count
    raise AssertionError('history command was not invalidated')


for run in range(3):
    with tempfile.TemporaryDirectory(prefix='orch-keys-') as tmp:
        workspace = Path(tmp)
        fixture(workspace)
        view = View(workspace)
        try:
            print(f'run {run + 1}')
            view.key(b'w', b'PLAN DAG', .6)
            view.key(b'j', b'LIVE VIEW > dev-1', .6)
            view.key(b'k', b'LIVE VIEW > dev-0', .6)
            f_on = view.key(b'f', b'attention only', .6)
            assert b'[f] show all' in f_on
            f_off = view.key(b'f', b'[f] attention', .6)
            assert b'attention only' not in f_off
            view.key(b'w', b'worker', .6)
            view.key(b'c', b'dev-0', .6)
            view.key(b'g', b'> dev-0 ', .6)
            view.key(b'j', b'> dev-1 ', .3)
            details = view.key(b'i', b'worker: dev-1', .6)
            # Independent fixture values catch details opening for the wrong selection.
            assert b'model: fixture-1' in details
            assert b'worker: dev-0' not in details
            assert b'd diff' in details and b'Esc back' in details
            view.key(b'\x1b', b'> dev-1 ', .3)
            view.key(b'jjjjj', b'> dev-6 ', .5)
            view.key(b'kkkkkk', b'> dev-0 ', .5)
            view.key(b'\x1b[B', b'> dev-1 ', .3)
            view.key(b'\x1b[A', b'> dev-0 ', .3)
            reloads = []
            for n in range(1, 11):
                if n in (1, 6):
                    previous = len((workspace / 'history-start').read_text().splitlines())
                    # Growing the database invalidates the production stamp even within a second.
                    with (workspace / '.squad/messages.db').open('a') as db:
                        db.write('x')
                    reloads.append(reload_start(view, workspace, previous))
                    print('during reload:', end=' ', flush=True)
                view.key(b'j', f'> dev-{n} '.encode(), .6)
            assert reloads[1] > reloads[0], 'must cross two reloads'
            view.key(b'i', b'worker: dev-10', .6)
            view.key(b'\x1b', b'> dev-10 ', .6)
            fcntl.ioctl(view.master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            os.kill(view.proc.pid, signal.SIGWINCH)
            view.frame(lambda f: b'> dev-10 ' in f, 2)
            view.quit()
        finally:
            view.close()

# A layout change and navigation in one write must not reuse removed worker indices.
with tempfile.TemporaryDirectory(prefix='orch-navigation-') as tmp:
    workspace = Path(tmp)
    fixture(workspace, 2)
    for path in (workspace / '.squad/workers').glob('*.status'):
        path.write_text(path.read_text().replace('state=completed', f'state=running\npid={os.getpid()}'))
    view = View(workspace, 'list')
    try:
        print('worker removal with buffered layout/navigation:', flush=True)
        view.key(b'g', b'> dev-0 ', .6)
        (workspace / '.squad/workers/dev-01.status').unlink()
        view.frame(lambda f: b'dev-1 ' not in f and b'> dev-0 ' in f, 4)
        view.key(b't', b'dev-0 ', .6)
        view.key(b'\tj', b'dev-0 ', .6)
        assert view.proc.poll() is None, 'buffered navigation killed the view'
        details = view.key(b'i', b'worker: dev-0', .6)
        assert b'model: fixture-0' in details
        view.quit()
    finally:
        view.close()

# `w` and Tab-from-graph reach the g2 swarm layout.
with tempfile.TemporaryDirectory(prefix='orch-g2-') as tmp:
    workspace = Path(tmp)
    fixture(workspace, 2)
    log = workspace / 'dev-0.log'
    log.write_text('worker output\n')
    for path in (workspace / '.squad/workers').glob('*.status'):
        path.write_text(path.read_text().replace('state=completed', f'state=running\npid={os.getpid()}'))
    first_worker = workspace / '.squad/workers/dev-00.status'
    first_worker.write_text(first_worker.read_text() + f'log={log}\n')
    first_worker.with_suffix('.live').write_text('tokens_in=1200\nactivity=Running checks\n')
    view = View(workspace, 'list')
    try:
        frame = view.key(b'w', b'PLAN DAG', 1)
        assert b'[c] cards' in frame and b'[g] graph' in frame and b'[w] swarm' in frame
        assert 'manager→dev-0 ▸ brief: brief AAA'.encode() in frame
        selected = next(line for line in frame.splitlines() if b'> dev-0 ' in line and b'elapsed ' in line)
        assert all(field in selected for field in (b'elapsed ', b'output ', b'1k tok', b'Running checks'))
        first_worker.with_suffix('.live').write_text('tokens_in=2400\nactivity=Checking results\n')
        view.frame(lambda f: any(
            b'> dev-0 ' in line and b'2k tok' in line and b'Checking results' in line
            for line in f.splitlines()
        ), 4)
        view.key(b'g', b'> dev-0 ', 1)
        view.key(b'w', b'PLAN DAG', 1)
        view.key(b'c', b'Legend:', 1)
        view.key(b'w', b'PLAN DAG', 1)
        view.key(b'g', b'> dev-0 ', 1)
        view.key(b'\t', b'PLAN DAG', 1)
        view.quit()
    finally:
        view.close()

# Verify visible history and worker membership after same-length history rewrites.
with tempfile.TemporaryDirectory(prefix='orch-invalidation-') as tmp:
    workspace = Path(tmp)
    fixture(workspace, 2)
    for path in (workspace / '.squad/workers').glob('*.status'):
        path.write_text(path.read_text().replace('state=completed', f'state=running\npid={os.getpid()}'))
    with (workspace / 'history').open('a') as history:
        history.write('[2026-11-20T00:01:00Z] dev-2 -> manager: QUESTION: newly added?\n')
    view = View(workspace, 'list')
    try:
        view.key(b'h', b'brief AAA', .6)
        history = workspace / 'history'
        old = history.read_text()
        history.write_text(old.replace('AAA', 'BBB'))
        assert history.stat().st_size == len(old)
        with (workspace / '.squad/messages.db').open('a') as db:
            db.write('x')
        frame = view.frame(lambda f: b'brief BBB' in f, 4)
        assert b'brief AAA' not in frame
        view.key(b'h', b'dev-1 ', .6)
        added = status(workspace, 2)
        added.write_text(added.read_text().replace('state=completed', f'state=running\npid={os.getpid()}'))
        view.frame(lambda f: b'dev-2 ' in f and b'newly added?' in f and b'waiting' in f, 4)
        added.unlink()
        view.frame(lambda f: b'dev-2 ' not in f and b'dev-1 ' in f, 4)
        # Unchanged mtime/size cannot suppress history refresh indefinitely.
        previous = len((workspace / 'history-start').read_text().splitlines())
        deadline = time.monotonic() + 12
        while len((workspace / 'history-start').read_text().splitlines()) == previous:
            assert time.monotonic() < deadline, '10-second forced history refresh missing'
            view.frame(lambda _: True, 2)
        view.quit()
    finally:
        view.close()

# Verify g2 attention filter hides non-attention workers from LIVE VIEW and j/k navigation.
with tempfile.TemporaryDirectory(prefix='orch-attention-') as tmp:
    workspace = Path(tmp)
    fixture(workspace, 3)
    view = View(workspace, 'g2')
    try:
        view.frame(lambda f: b'LIVE VIEW > dev-0' in f, 2)
        empty_attn = view.key(b'f', b'LIVE VIEW > no worker', .6)
        assert b'WORKERS (0/3)' in empty_attn
        assert b'No workers needing attention' in empty_attn
        assert b'no attention needed' in empty_attn
        # j/k must not select hidden workers when attention filter is empty.
        still_empty = view.key(b'j', b'LIVE VIEW > no worker', .6)
        assert b'LIVE VIEW > dev-' not in still_empty
        # Esc exits attention filter.
        exited = view.key(b'\x1b', b'LIVE VIEW > dev-0', .6)
        assert b'attention only' not in exited

        # Mark dev-1 as failed and dev-2 as ready to merge (completed + worktree).
        s1 = status(workspace, 1)
        s1.write_text(s1.read_text().replace('state=completed', 'state=failed'))
        s2 = status(workspace, 2)
        s2.write_text(s2.read_text() + f'worktree={workspace}\n')
        with (workspace / '.squad/messages.db').open('a') as db:
            db.write('x')
        view.frame(lambda f: b'NEEDS ATTENTION (2)' in f, 4)
        attn = view.key(b'f', b'WORKERS (2/3)', .6)
        assert b'LIVE VIEW > dev-1' in attn
        # j/k cycles only through attention workers (dev-1 <-> dev-2), skipping dev-0.
        nxt = view.key(b'j', b'LIVE VIEW > dev-2', .6)
        assert b'LIVE VIEW > dev-0' not in nxt
        wrapped = view.key(b'j', b'LIVE VIEW > dev-1', .6)
        assert b'LIVE VIEW > dev-0' not in wrapped
        view.quit()
    finally:
        view.close()

print('squad orchestration keys smoke: OK')
