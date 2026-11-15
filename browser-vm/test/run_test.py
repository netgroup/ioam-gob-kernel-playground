#!/usr/bin/env python3
"""Headless browser test of the GOB browser VM.

Runs in the Playwright container. Serves /work/site with a plain static
server (no COOP/COEP headers, like GitHub Pages: coi-serviceworker must do
its job), opens index.html?test=1, and reads the VM terminal until the self
test of gob-init ends (demo, clang build, demo again, interactive demo).

Usage: run_test.py [browser] [timeout_s] [extra_query] [tag]
  browser      chromium (default), firefox or webkit
  timeout_s    default 1500
  extra_query  appended to the URL, e.g. "&mem=768M"
  tag          name of the log files, default the browser name

Writes /work/logs/test-<tag>.log (timeline) and test-<tag>.screen (the
whole terminal at the end). Exit code 0 only if every check passed.
"""
import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

browser_name = sys.argv[1] if len(sys.argv) > 1 else 'chromium'
timeout_s = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
extra = sys.argv[3] if len(sys.argv) > 3 else ''
tag = sys.argv[4] if len(sys.argv) > 4 else browser_name
log = open(f'/work/logs/test-{tag}.log', 'w', buffering=1)

MARKS = ('GOBTEST_BEGIN', 'GOB_DEMO_5NODE_RECV=', 'GOBTEST_END', 'CLANGTEST_END',
         'GOBTEST2_BEGIN', 'GOBTEST2_END', 'GOBTEST3_BEGIN', 'GOBTEST3_END')
READ_TERM = '''() => { if (!window.gobTerm) return null;
  const b = window.gobTerm.buffer.active; const out = [];
  for (let i = 0; i < b.length; i++) out.push(b.getLine(i).translateToString(true));
  return out; }'''


def say(msg):
    line = f'[{time.strftime("%H:%M:%S")}] {msg}'
    print(line, flush=True)
    log.write(line + '\n')


srv = subprocess.Popen([sys.executable, '-m', 'http.server', '8000', '-d', '/work/site'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(1)
t0 = time.time()
marks = {}
lines = []
with sync_playwright() as p:
    br = getattr(p, browser_name).launch(headless=True)
    page = br.new_page()
    page.on('console', lambda m: say(f'console.{m.type}: {m.text[:300]}'))
    page.on('pageerror', lambda e: say(f'pageerror: {e}'))
    page.goto('http://localhost:8000/index.html?test=1' + extra)
    seen = 0
    while time.time() - t0 < timeout_s:
        time.sleep(5)
        try:
            cur = page.evaluate(READ_TERM)
            coi = page.evaluate('() => self.crossOriginIsolated')
        except Exception as e:
            say(f'evaluate failed: {e}')
            if 'crashed' in str(e):
                break
            continue
        if coi and 'coi' not in marks:
            marks['coi'] = time.time() - t0
            say(f'MARK crossOriginIsolated at {marks["coi"]:.0f}s')
        if cur is None:
            continue
        while cur and cur[-1] == '':
            cur.pop()
        lines = cur
        # The terminal can redraw lines already read (the BIOS clears the
        # screen), so the markers are searched in the whole buffer, and only
        # the new lines are logged.
        for l in lines[seen:]:
            say('VM| ' + l)
        seen = max(seen, len(lines))
        for l in lines:
            for key in MARKS + ('NPROC=',):
                if key in l and key not in marks:
                    marks[key] = time.time() - t0
                    say(f'MARK {key} at {marks[key]:.0f}s')
        if 'GOBTEST3_END' in marks:
            break
    br.close()
srv.terminate()
open(f'/work/logs/test-{tag}.screen', 'w').write('\n'.join(lines) + '\n')


def has(text):
    return any(text in l for l in lines)


checks = {
    'cross-origin isolated': 'coi' in marks,
    'one vCPU (NPROC=1)': has('NPROC=1'),
    'demo PASS twice': sum('GOB_DEMO_5NODE_RECV=PASS' in l for l in lines) == 2,
    'no demo FAIL': not has('GOB_DEMO_5NODE_RECV=FAIL'),
    'demo exit 0 (first run)': has('GOBTEST_END rc=0'),
    'clang build exit 0': any('CLANGTEST_END rc=0' in l for l in lines),
    'demo exit 0 (with the object built in the VM)': has('GOBTEST2_END rc=0'),
    'interactive demo exit 0': has('GOBTEST3_END rc=0'),
    'interactive demo: node 5 got min 10 max 70 sum 140 count 4 after n3=70':
        any(' '.join(l.split()).startswith('5 | 10 | 70 | 140 | 4 |') for l in lines),
}
for name, ok in checks.items():
    say(f'{"OK  " if ok else "FAIL"} {name}')
say('timeline: ' + ', '.join(f'{k} {v:.0f}s' for k, v in marks.items()))
for l in lines:
    if l.startswith('CLANGTEST_END') or l.startswith('OBJ '):
        say(l)
ok = all(checks.values())
say(f'BROWSER_VM_TEST={"PASS" if ok else "FAIL"} ({time.time() - t0:.0f}s)')
sys.exit(0 if ok else 1)
