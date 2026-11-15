#!/usr/bin/env python3
"""Quick browser test of the GOB browser VM: about a minute.

For changes to the page. It does not replace run_test.py, which must pass
before a publication. Serves /work/site like run_test.py, opens the page
(no ?test=1), waits for the shell prompt, runs a few commands and checks
their output, checks that the gob-* commands are in the PATH of the shell
and that tmux draws, and logs how long python3 takes to start.

Writes /work/logs/test-quick.log. Exit code 0 only if every check passed.
"""
import re
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

log = open('/work/logs/test-quick.log', 'w', buffering=1)
READ_TERM = '''() => { if (!window.gobTerm) return null;
  const b = window.gobTerm.buffer.active; const out = [];
  for (let i = 0; i < b.length; i++) out.push(b.getLine(i).translateToString(true));
  return out; }'''


def say(msg):
    line = f'[{time.strftime("%H:%M:%S")}] {msg}'
    print(line, flush=True)
    log.write(line + '\n')


def lines(page):
    try:
        return page.evaluate(READ_TERM) or []
    except Exception:
        return []


def wait_line(page, pattern, timeout):
    """A whole terminal line matching pattern: output, not the typed command."""
    rx = re.compile(pattern)
    end = time.time() + timeout
    while time.time() < end:
        for l in lines(page):
            if rx.fullmatch(l.strip()):
                return True
        time.sleep(1)
    return False


srv = subprocess.Popen([sys.executable, '-m', 'http.server', '8000', '-d', '/work/site'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
t0 = time.time()
checks = {}
with sync_playwright() as p:
    br = p.chromium.launch(headless=True)
    page = br.new_page(viewport={'width': 1280, 'height': 860})
    page.on('pageerror', lambda e: say(f'pageerror: {e}'))
    page.goto('http://localhost:8000/')
    checks['shell prompt'] = wait_line(page, r'root@gob:~#', 180)
    say(f'shell prompt after {time.time() - t0:.0f}s')
    # the page checks for the prompt once a second: give it a few seconds
    for _ in range(10):
        if page.evaluate("() => document.getElementById('status').textContent").startswith('Ready'):
            break
        time.sleep(1)
    checks['page status Ready'] = page.evaluate(
        "() => document.getElementById('status').textContent").startswith('Ready')
    page.click('#terminal')
    page.keyboard.type('uname -r; ip -V; bpftool version | head -1; clang --version | head -1; '
                       'stty size; echo QUICK_DONE=$?', delay=10)
    page.keyboard.press('Enter')
    checks['commands ran'] = wait_line(page, r'QUICK_DONE=0', 120)
    out = '\n'.join(lines(page))
    checks['kernel 6.18'] = '6.18.0' in out
    checks['ip with libbpf'] = 'ip utility, iproute2' in out
    checks['bpftool'] = 'bpftool v' in out
    checks['clang'] = 'clang version 19' in out
    checks['terminal size set (stty size is not 0 0)'] = any(
        re.fullmatch(r'[1-9]\d* [1-9]\d*', l.strip()) for l in lines(page))

    def run(cmd, marker, timeout=120):
        page.keyboard.type(f'clear; {cmd}; echo {marker}=$?', delay=10)
        page.keyboard.press('Enter')
        return wait_line(page, marker + r'=\d+', timeout)

    # The gob-* commands of the welcome message, from the login shell.
    run('command -v gob-help gob-demo-5node-recv-tmux.sh', 'GH')
    found = {l.strip() for l in lines(page)}
    checks['gob-* commands and demo scripts in the PATH of the shell'] = (
        '/mnt/scripts/gob-demo/bin/gob-help' in found and
        '/mnt/scripts/gob-demo/gob-demo-5node-recv-tmux.sh' in found)
    # Cost of starting Python, for the record (not a check).
    run('time python3 -c pass', 'PY', 180)
    real = [l.split()[1] for l in lines(page) if l.startswith('real')]
    say(f'python3 -c pass: real {real[-1] if real else "?"}')
    # tmux draws: attach to a session running top, then detach.
    run('tmux new-session -d -s quick "top -d 2"', 'TN', 60)
    page.keyboard.type('tmux attach -t quick', delay=10)
    page.keyboard.press('Enter')
    drawn = False
    for _ in range(40):
        time.sleep(1)
        if page.evaluate('() => window.gobTerm.buffer.active.type') == 'alternate' and \
                any(l.startswith('Tasks:') for l in lines(page)):
            drawn = True
            break
    checks['tmux draws (attach shows top inside tmux)'] = drawn
    page.keyboard.press('Control+b')
    page.keyboard.press('d')
    checks['tmux detaches'] = wait_line(page, r'\[detached \(from session quick\)\]', 60)
    br.close()
srv.terminate()
for name, ok in checks.items():
    say(f'{"OK  " if ok else "FAIL"} {name}')
ok = all(checks.values())
say(f'BROWSER_VM_QUICK_TEST={"PASS" if ok else "FAIL"} ({time.time() - t0:.0f}s)')
sys.exit(0 if ok else 1)
