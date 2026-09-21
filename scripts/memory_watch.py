#!/usr/bin/env python3
"""One read-only DockVU memory and display check for hourly launchd execution."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / 'build' / 'diagnostics' / 'memory-watch'
BUDGET_MB = 100
HEARTBEAT_PATH = Path.home() / "Library/Caches/local.dockvu.app/health.json"


def footprint_mb(report):
    match = re.search(r'^Physical footprint:\s+([\d.]+)([KMGT]?)', report, re.MULTILINE)
    if not match:
        raise ValueError('vmmap did not report a physical footprint')
    value, unit = match.groups()
    return float(value) * 1024 ** (' KMGT'.index(unit or ' ') - 2)


def assess(current, history):
    if current['footprint_mb'] > BUDGET_MB:
        return 'over_budget'
    # Compare only this exact process lifetime, not separate launches or recycled PIDs.
    samples = [row for row in history if row.get('process') == current['process']
               and 'footprint_mb' in row][-3:] + [current]
    if len(samples) == 4:
        sizes = [row['footprint_mb'] for row in samples]
        elapsed = (dt.datetime.fromisoformat(samples[-1]['time'])
                   - dt.datetime.fromisoformat(samples[0]['time'])).total_seconds()
        if elapsed >= 2.5 * 3600 and all(b > a for a, b in zip(sizes, sizes[1:])) and sizes[-1] - sizes[0] >= 10:
            return 'sustained_growth'
    return 'within_budget'


def heartbeat_status(heartbeat, pid, now):
    if not isinstance(heartbeat, dict) or heartbeat.get('pid') != pid:
        return 'heartbeat_missing'
    refreshed = heartbeat.get('last_refresh')
    if not isinstance(refreshed, (float, int)):
        return 'heartbeat_missing'
    age = now - refreshed
    return 'display_stalled' if age > 30 else 'responsive'


def run(command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=30)


def main():
    REPORTS.mkdir(parents=True, exist_ok=True)
    history_path = REPORTS / 'history.jsonl'
    history = [json.loads(line) for line in history_path.read_text().splitlines()] if history_path.exists() else []
    now = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    rows = []
    try:
        processes = subprocess.run(['/usr/bin/pgrep', '-x', '-u', str(os.getuid()), 'DockVU'],
                                   capture_output=True, text=True, timeout=10)
        if processes.returncode not in (0, 1):
            raise RuntimeError(processes.stderr.strip() or 'pgrep failed')
        for pid_text in processes.stdout.split():
            pid = int(pid_text)
            started = run(['/bin/ps', '-p', str(pid), '-o', 'lstart=']).strip()
            if not started:
                continue
            current = {'time': now, 'pid': pid, 'process': f'{pid}:{started}', 'budget_mb': BUDGET_MB}
            try:
                report = run(['/usr/bin/vmmap', '-summary', str(pid)])
                current['footprint_mb'] = round(footprint_mb(report), 3)
                current['status'] = assess(current, history)
                try:
                    heartbeat = json.loads(HEARTBEAT_PATH.read_text())
                    current['display_status'] = heartbeat_status(heartbeat, pid, time.time())
                    if current['display_status'] == 'display_stalled':
                        # A calendar job can run immediately on wake; allow a fresh UI tick.
                        time.sleep(6)
                        heartbeat = json.loads(HEARTBEAT_PATH.read_text())
                        current['display_status'] = heartbeat_status(heartbeat, pid, time.time())
                except (OSError, ValueError):
                    current['display_status'] = 'heartbeat_missing'
                # Keep one latest raw report per process; history remains small scalar records.
                (REPORTS / 'latest-vmmap.txt').write_text(report)
            except (subprocess.SubprocessError, ValueError) as error:
                current.update(status='check_failed', error=str(error))
            rows.append(current)
        if not rows:
            rows.append({'time': now, 'status': 'not_running'})
    except (subprocess.SubprocessError, RuntimeError) as error:
        rows.append({'time': now, 'status': 'check_failed', 'error': str(error)})

    # Bounded retention: 90 days of hourly checks, including restart/error records.
    history = (history + rows)[-2160:]
    temporary = history_path.with_suffix('.tmp')
    temporary.write_text(''.join(json.dumps(row) + '\n' for row in history))
    temporary.replace(history_path)
    (REPORTS / 'latest.json').write_text(json.dumps(rows, indent=2) + '\n')
    for row in rows:
        print(json.dumps(row), flush=True)
        if (row['status'] in ('over_budget', 'sustained_growth', 'check_failed')
                or row.get('display_status') in ('display_stalled', 'heartbeat_missing')):
            message = (f"DockVU: {row['status'].replace('_', ' ')}; {row.get('display_status', 'unknown').replace('_', ' ')}"
                       + (f" ({row['footprint_mb']:.1f} MiB)." if 'footprint_mb' in row else '.')
                       + ' See build/diagnostics/memory-watch/latest.json.')
            # Message is an argv value, never interpolated into AppleScript source.
            subprocess.run(['/usr/bin/osascript', '-e',
                            'on run argv\ndisplay notification (item 1 of argv) with title "DockVU memory watch"\nend run',
                            message], timeout=15, check=False)


if __name__ == '__main__':
    main()
