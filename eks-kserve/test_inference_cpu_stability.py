#!/usr/bin/env python3
"""Continuously probe the CPU iris InferenceService and report stability runs.

Sends a prediction request every --interval-ms and groups consecutive
requests with the same outcome (OK vs FAIL) into a "run". Prints one line
per run only when the outcome flips, so the terminal stays quiet during
long stable stretches and shouts when behaviour changes.

Each line reports the run's wall-clock start/end, duration, number of
requests, and success rate — green for all-OK runs, red for any-FAIL run.

Setup (from eks-kserve/):
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt

Usage:
  .venv/bin/python ./test_inference_cpu_stability.py
  .venv/bin/python ./test_inference_cpu_stability.py --interval-ms 500
  .venv/bin/python ./test_inference_cpu_stability.py --interval-ms 200 --timeout 5

Stop with Ctrl+C — the in-progress run is flushed before exiting.
"""

from __future__ import annotations

import argparse
import datetime as dt
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

try:
    import requests
    from rich.console import Console
    from rich.live import Live
    from rich.text import Text
except ImportError:
    _here = Path(__file__).resolve().parent
    sys.stderr.write(
        "This script requires 'rich' and 'requests'. Set up the local venv:\n"
        f"  cd {_here}\n"
        "  python3 -m venv .venv\n"
        "  .venv/bin/pip install -r requirements.txt\n"
        f"  .venv/bin/python {Path(__file__).name}\n"
    )
    sys.exit(2)

console = Console()

PAYLOAD = {"instances": [[6.8, 2.8, 4.8, 1.4]]}
HEADERS = {"Content-Type": "application/json"}


def get_terraform_url() -> str:
    iac = Path(__file__).resolve().parent / "iac"
    out = subprocess.run(
        ["terraform", f"-chdir={iac}", "output", "-raw", "iris_url"],
        check=True, capture_output=True, text=True,
    )
    return out.stdout.strip()


@dataclass
class Run:
    ok: bool
    start: dt.datetime
    end: dt.datetime
    total: int = 0
    failures: int = 0
    # Keep a few sample failure reasons so the printed line is informative.
    sample_reasons: list[str] = field(default_factory=list)

    def add(self, ok: bool, ts: dt.datetime, reason: str = "") -> None:
        self.total += 1
        self.end = ts
        if not ok:
            self.failures += 1
            if reason and reason not in self.sample_reasons and len(self.sample_reasons) < 3:
                self.sample_reasons.append(reason)


def fmt_duration(seconds: float) -> str:
    if seconds < 1:
        return f"{seconds * 1000:.0f}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{int(m)}m{s:04.1f}s"
    h, m = divmod(m, 60)
    return f"{int(h)}h{int(m):02d}m{s:04.1f}s"


def _run_markup(run: Run, end_ts: dt.datetime, live: bool) -> str:
    duration = (end_ts - run.start).total_seconds()
    start_s = run.start.strftime("%H:%M:%S")
    end_s = end_ts.strftime("%H:%M:%S")
    suffix = " [dim]…[/dim]" if live else ""
    if run.ok:
        return (
            f"[green]OK  [/green] {start_s} → {end_s}  "
            f"({fmt_duration(duration)}, {run.total} requests){suffix}"
        )
    reasons = ("; ".join(run.sample_reasons)) if run.sample_reasons else "—"
    return (
        f"[red]FAIL[/red] {start_s} → {end_s}  "
        f"({fmt_duration(duration)}, {run.failures}/{run.total} failed)  "
        f"[dim]{reasons}[/dim]{suffix}"
    )


def print_run(run: Run) -> None:
    console.print(_run_markup(run, run.end, live=False))


def live_renderable(run: Run) -> Text:
    return Text.from_markup(_run_markup(run, dt.datetime.now(), live=True))


def probe(session: requests.Session, url: str, timeout: float) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty on success."""
    try:
        resp = session.post(url, json=PAYLOAD, headers=HEADERS, timeout=timeout)
    except requests.Timeout:
        return False, f"timeout>{timeout}s"
    except requests.ConnectionError as exc:
        return False, f"conn: {type(exc).__name__}"
    except requests.RequestException as exc:
        return False, f"req: {type(exc).__name__}"
    if resp.status_code != 200:
        return False, f"HTTP {resp.status_code}"
    if '"predictions"' not in resp.text:
        return False, "no predictions field"
    return True, ""


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--interval-ms", type=int, default=100, metavar="MS",
                    help="delay between requests in milliseconds (default: 100)")
    ap.add_argument("--timeout", type=float, default=10.0, metavar="SECONDS",
                    help="per-request HTTP timeout in seconds (default: 10)")
    ap.add_argument("--url", type=str, default=None,
                    help="override terraform-provided iris URL")
    args = ap.parse_args()

    url = args.url or get_terraform_url()
    interval = args.interval_ms / 1000.0

    console.rule("[bold]KServe CPU iris stability probe[/bold]")
    console.print(f"URL:      [cyan]{url}[/cyan]")
    console.print(f"Interval: {args.interval_ms}ms")
    console.print(f"Timeout:  {args.timeout}s per request")
    console.print("[dim]One line per outcome change. Ctrl+C to stop.[/dim]")
    console.print()

    session = requests.Session()
    current: Run | None = None
    stopping = False

    def _stop(signum: int, frame) -> None:  # noqa: ARG001
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    live = Live("", console=console, transient=True,
                refresh_per_second=4, auto_refresh=True)
    live.start()
    try:
        while not stopping:
            loop_start = time.monotonic()
            ok, reason = probe(session, url, args.timeout)
            ts = dt.datetime.now()

            if current is None:
                current = Run(ok=ok, start=ts, end=ts)
                current.add(ok, ts, reason)
            elif current.ok == ok:
                current.add(ok, ts, reason)
            else:
                # Flip: drop the transient live line, emit the finalized
                # line, then restart the live for the new run.
                live.stop()
                print_run(current)
                current = Run(ok=ok, start=ts, end=ts)
                current.add(ok, ts, reason)
                live.start()

            live.update(live_renderable(current))

            remaining = interval - (time.monotonic() - loop_start)
            if remaining > 0 and not stopping:
                # Sleep in short slices so Ctrl+C flushes promptly and the
                # live duration ticks even when --interval-ms is large.
                deadline = time.monotonic() + remaining
                while not stopping and time.monotonic() < deadline:
                    time.sleep(min(0.2, deadline - time.monotonic()))
                    live.update(live_renderable(current))
    finally:
        live.stop()
        if current is not None:
            print_run(current)

    return 0


if __name__ == "__main__":
    sys.exit(main())
