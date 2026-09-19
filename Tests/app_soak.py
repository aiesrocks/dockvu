"""Run the actual app long enough to cover the reported 14–102 second crashes.

Usage: python3 Tests/app_soak.py [--demo] [--seconds 180]
Leaves a passing instance running; the user can quit it normally.
"""
import argparse
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--demo', action='store_true')
parser.add_argument('--seconds', type=int, default=180)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
log = root / 'build' / 'diagnostics' / 'soak.log'
log.parent.mkdir(parents=True, exist_ok=True)
command = [str(root / 'build' / 'DockVU.app' / 'Contents' / 'MacOS' / 'DockVU')]
if args.demo:
    command.append('--demo')
with log.open('w') as stream:
    process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
print(f'Started DockVU PID {process.pid}', flush=True)
started = time.monotonic()
next_report = 30
while time.monotonic() - started < args.seconds:
    if process.poll() is not None:
        raise SystemExit(f'FAIL: app exited with {process.returncode}\n{log.read_text()}')
    elapsed = time.monotonic() - started
    if elapsed >= next_report:
        print(f'Alive at {int(elapsed)} seconds', flush=True)
        next_report += 30
    time.sleep(1)
print(f'PASS: app remained running for {args.seconds} seconds; left open for use.', flush=True)
