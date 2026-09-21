"""Run the actual app long enough to cover the reported 14–102 second crashes.

Usage: python3 Tests/app_soak.py [--demo] [--seconds 180]
Leaves a passing instance running; the user can quit it normally.
"""
import argparse
import pathlib
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--demo', action='store_true')
parser.add_argument('--verify-audio', action='store_true', help='Require live callbacks from both captures')
parser.add_argument('--max-footprint-mb', type=float, default=200, help='Full physical footprint budget, including swapped allocations')
parser.add_argument('--seconds', type=int, default=180)
args = parser.parse_args()
if args.seconds < 31:
    parser.error('--seconds must be at least 31 to include a health check')
root = pathlib.Path(__file__).resolve().parents[1]
log = root / 'build' / 'diagnostics' / 'soak.log'
log.parent.mkdir(parents=True, exist_ok=True)
command = [str(root / 'build' / 'DockVU.app' / 'Contents' / 'MacOS' / 'DockVU')]
if args.demo:
    command.append('--demo')
if args.verify_audio:
    if args.demo:
        parser.error('--verify-audio cannot be used with --demo')
    command.append('--diagnostics')
with log.open('w') as stream:
    process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
print(f'Started DockVU PID {process.pid}', flush=True)
started = time.monotonic()
next_report = 30
previous_counts = (0, 0)
while time.monotonic() - started < args.seconds:
    if process.poll() is not None:
        raise SystemExit(f'FAIL: app exited with {process.returncode}\n{log.read_text()}')
    elapsed = time.monotonic() - started
    if elapsed >= next_report:
        memory = subprocess.check_output(['vmmap', '-summary', str(process.pid)], text=True, timeout=20)
        footprint = re.search(r'^Physical footprint:\s+([\d.]+)([KMGT]?)', memory, re.MULTILINE)
        if not footprint:
            raise SystemExit('FAIL: could not read physical memory footprint')
        value, unit = footprint.groups()
        footprint_mb = float(value) * (1024 ** (' KMGT'.index(unit or ' ') - 2))
        if footprint_mb > args.max_footprint_mb:
            raise SystemExit(f'FAIL: footprint {footprint_mb:.1f} MiB exceeds {args.max_footprint_mb:g} MiB budget')
        if args.verify_audio:
            matches = re.findall(r'inputCallbacks=(\d+) outputCallbacks=(\d+)', log.read_text())
            if not matches:
                raise SystemExit(f'FAIL: no audio health reports; see {log}')
            counts = tuple(map(int, matches[-1]))
            if any(current <= previous for current, previous in zip(counts, previous_counts)):
                raise SystemExit(f'FAIL: callbacks stopped: {previous_counts} -> {counts}; see {log}')
            previous_counts = counts
            print(f'Audio callbacks: input={counts[0]}, output={counts[1]}', flush=True)
        print(f'Alive at {int(elapsed)} seconds; footprint={footprint_mb:.1f} MiB / {args.max_footprint_mb:g} MiB', flush=True)
        next_report += 30
    time.sleep(1)
print(f'PASS: app remained running for {args.seconds} seconds; left open for use.', flush=True)
