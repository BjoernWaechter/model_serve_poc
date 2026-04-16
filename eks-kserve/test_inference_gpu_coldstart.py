#!/usr/bin/env python3
"""Measure GPU cold-start latency for the llm1 (Phi-3-mini / vLLM) InferenceService.

Sends the same chat request as test_inference_gpu.sh, but instruments the
whole scale-from-zero pipeline using kubectl + requests and prints a
timeline of every phase relative to the moment the request was sent.

Phases captured:
  * Cluster autoscaler provisioning a new GPU node
      ASG -> EC2 boot -> Node Ready -> nvidia.com/gpu device plugin Ready
  * KServe revision pod lifecycle
      created -> PodScheduled -> image pull -> storage-initializer (model dl)
      -> Initialized -> kserve-container started -> ContainersReady -> Ready
  * HTTP timing (time-to-first-byte and total)

Setup (one-time, from the eks-kserve/ directory):
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt

Usage:
  .venv/bin/python ./test_inference_gpu_coldstart.py
  .venv/bin/python ./test_inference_gpu_coldstart.py --force-cold    # delete existing pods
  .venv/bin/python ./test_inference_gpu_coldstart.py --wait-zero 180 # wait up to 180s for
                                                                     # Knative to scale to 0

Or activate the venv first (`source .venv/bin/activate`) and call the script
directly.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import requests as _requests_check  # noqa: F401
    from rich import box
    from rich.console import Console
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
except ImportError:
    _here = Path(__file__).resolve().parent
    sys.stderr.write(
        "This script requires 'rich' and 'requests'. Set up the local venv:\n"
        f"  cd {_here}\n"
        "  python3 -m venv .venv\n"
        "  .venv/bin/pip install -r requirements.txt\n"
        "  .venv/bin/python " + Path(__file__).name + "\n"
    )
    sys.exit(2)
import requests

console = Console()

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NS = "kserve-test"
ISVC = "llm1"
LABEL = f"serving.kserve.io/inferenceservice={ISVC}"
GPU_NODE_SELECTOR = "inference/type=gpu"  # only GPU inference nodes
DEVICE_PLUGIN_LABEL = "app=nvidia-device-plugin-daemonset"

CHAT_PAYLOAD = {
    "model": "model",
    "messages": [{"role": "user", "content": "Explain a Hopper in NZ in 200 words"}],
    "max_tokens": 100,
}

REQUEST_TIMEOUT = 600  # seconds
WATCH_INTERVAL = 3   # seconds — purely cosmetic live status

ARTEFACT_DIR = Path("/tmp")
RESPONSE_FILE = ARTEFACT_DIR / "kserve_coldstart_response.json"
WATCH_LOG = ARTEFACT_DIR / "kserve_coldstart_watch.log"
RESULT_JSON = ARTEFACT_DIR / "kserve_coldstart_result.json"


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def require_binaries(*bins: str) -> None:
    missing = [b for b in bins if shutil.which(b) is None]
    if missing:
        sys.exit(f"missing required binary: {', '.join(missing)}")


def run(cmd: list[str], *, check: bool = True, capture: bool = True,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture,
        text=True,
        timeout=timeout,
    )


def kubectl_json(*args: str) -> dict[str, Any]:
    """Run kubectl ... -o json and parse the result. Returns {} on failure."""
    try:
        out = run(["kubectl", *args, "-o", "json"], check=False)
    except FileNotFoundError:
        return {}
    if out.returncode != 0 or not out.stdout.strip():
        return {}
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}


def parse_ts(ts: str | None) -> dt.datetime | None:
    """Parse an RFC3339 timestamp (e.g. 2026-04-15T22:14:08Z) -> aware datetime."""
    if not ts:
        return None
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def fmt_delta(seconds: float | None) -> str:
    """Format a delta in seconds as e.g. '    12.3s' or ' 2m43.1s'."""
    if seconds is None:
        return "    n/a   "
    sign = "-" if seconds < 0 else " "
    s = abs(seconds)
    m, s = divmod(s, 60)
    if m:
        return f"{sign}{int(m):2d}m{s:5.1f}s"
    return f"{sign}    {s:5.1f}s"


def delta(t0: dt.datetime, ts: dt.datetime | None) -> float | None:
    return None if ts is None else (ts - t0).total_seconds()


def first_condition_time(obj: dict, *types: str) -> dt.datetime | None:
    """Pick the lastTransitionTime of the first matching True condition."""
    for c in (obj.get("status", {}) or {}).get("conditions", []) or []:
        if c.get("type") in types and c.get("status") == "True":
            return parse_ts(c.get("lastTransitionTime"))
    return None


# ---------------------------------------------------------------------------
# Snapshot helpers
# ---------------------------------------------------------------------------
def list_pod_uids() -> set[str]:
    data = kubectl_json("get", "pod", "-n", NS, "-l", LABEL)
    return {item["metadata"]["uid"] for item in data.get("items", [])}


def list_node_uids() -> set[str]:
    data = kubectl_json("get", "nodes", "-l", GPU_NODE_SELECTOR)
    return {item["metadata"]["uid"] for item in data.get("items", [])}


def get_terraform_url() -> str:
    iac = Path(__file__).resolve().parent / "iac"
    out = run(["terraform", f"-chdir={iac}", "output", "-raw", "llm1_url"])
    return out.stdout.strip()


# ---------------------------------------------------------------------------
# Live watcher (cosmetic) — authoritative timestamps come from the post-mortem
# ---------------------------------------------------------------------------
class Watcher(threading.Thread):
    def __init__(self) -> None:
        super().__init__(daemon=True)
        self._stop = threading.Event()
        WATCH_LOG.write_text("")

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        while not self._stop.is_set():
            ts = dt.datetime.now().strftime("%H:%M:%S")
            pods = run(
                ["kubectl", "get", "pod", "-n", NS, "-l", LABEL,
                 "-o", "custom-columns=NAME:.metadata.name,PHASE:.status.phase,"
                       "NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready",
                 "--no-headers"],
                check=False,
            ).stdout.strip()
            nodes_count = len(
                run(["kubectl", "get", "nodes", "-l", GPU_NODE_SELECTOR,
                     "--no-headers"], check=False).stdout.strip().splitlines()
            )
            with WATCH_LOG.open("a") as f:
                f.write(f"[{ts}] inference_nodes={nodes_count}\n")
                if pods:
                    f.write(f"[{ts}] pods:\n")
                    for line in pods.splitlines():
                        f.write(f"    {line}\n")
            self._stop.wait(WATCH_INTERVAL)


# ---------------------------------------------------------------------------
# HTTP request via requests library
# ---------------------------------------------------------------------------
@dataclass
class HttpResult:
    http_code: str = ""
    error: str = ""
    ttfb: float | None = None
    total: float | None = None
    body: str = ""


def fire_request(url: str) -> tuple[dt.datetime, dt.datetime, HttpResult]:
    res = HttpResult()
    t0 = dt.datetime.now(dt.timezone.utc)
    try:
        resp = requests.post(
            url,
            json=CHAT_PAYLOAD,
            timeout=REQUEST_TIMEOUT,
            headers={"Content-Type": "application/json"},
        )
        t1 = dt.datetime.now(dt.timezone.utc)
        res.http_code = str(resp.status_code)
        res.total = resp.elapsed.total_seconds()
        res.ttfb = resp.elapsed.total_seconds()
        res.body = resp.text
        RESPONSE_FILE.write_text(resp.text)
    except requests.RequestException as exc:
        t1 = dt.datetime.now(dt.timezone.utc)
        res.error = str(exc)
    return t0, t1, res


# ---------------------------------------------------------------------------
# Post-mortem: extract authoritative timestamps
# ---------------------------------------------------------------------------
@dataclass
class PodTimeline:
    name: str = ""
    node: str = ""
    created: dt.datetime | None = None
    pod_scheduled: dt.datetime | None = None
    initialized: dt.datetime | None = None
    containers_ready: dt.datetime | None = None
    ready: dt.datetime | None = None
    storage_init_started: dt.datetime | None = None
    storage_init_finished: dt.datetime | None = None
    kserve_started: dt.datetime | None = None
    image_pull_started: dt.datetime | None = None
    image_pull_finished: dt.datetime | None = None
    image_pull_event_text: str = ""


@dataclass
class NodeTimeline:
    name: str = ""
    created: dt.datetime | None = None
    ready: dt.datetime | None = None
    device_plugin_ready: dt.datetime | None = None


def pick_new_pods(baseline: set[str]) -> list[dict]:
    """All pods with UIDs not in the baseline, oldest → newest."""
    data = kubectl_json("get", "pod", "-n", NS, "-l", LABEL)
    items = data.get("items", [])
    new = [p for p in items if p["metadata"]["uid"] not in baseline]
    new.sort(key=lambda p: p["metadata"].get("creationTimestamp", ""))
    return new


def pick_primary_pod(baseline: set[str]) -> dict | None:
    """Pod whose lifecycle we timeline in detail.

    Prefer the newest *new* pod (true cold start); fall back to the newest
    existing pod (warm path where we just hit a live replica).
    """
    data = kubectl_json("get", "pod", "-n", NS, "-l", LABEL)
    items = data.get("items", [])
    if not items:
        return None
    new = [p for p in items if p["metadata"]["uid"] not in baseline]
    pool = new or items
    pool.sort(key=lambda p: p["metadata"].get("creationTimestamp", ""))
    return pool[-1]


def pick_new_nodes(baseline: set[str]) -> list[dict]:
    """All inference nodes with UIDs not in the baseline, oldest → newest.

    Returns a list because the cluster autoscaler frequently provisions more
    than one node in response to a single scale-from-zero (e.g. when a second
    pod replica is requested, or when ASG over-provisions and then drains).
    """
    data = kubectl_json("get", "nodes", "-l", GPU_NODE_SELECTOR)
    items = data.get("items", [])
    new = [n for n in items if n["metadata"]["uid"] not in baseline]
    new.sort(key=lambda n: n["metadata"].get("creationTimestamp", ""))
    return new


def extract_pod_timeline(pod: dict) -> PodTimeline:
    pt = PodTimeline()
    pt.name = pod["metadata"]["name"]
    pt.node = pod.get("spec", {}).get("nodeName", "") or ""
    pt.created = parse_ts(pod["metadata"].get("creationTimestamp"))
    pt.pod_scheduled = first_condition_time(pod, "PodScheduled")
    pt.initialized = first_condition_time(pod, "Initialized")
    pt.containers_ready = first_condition_time(pod, "ContainersReady")
    pt.ready = first_condition_time(pod, "Ready")

    for ic in (pod.get("status", {}).get("initContainerStatuses") or []):
        if ic.get("name") == "storage-initializer":
            term = (ic.get("state") or {}).get("terminated") or {}
            running = (ic.get("state") or {}).get("running") or {}
            pt.storage_init_started = parse_ts(term.get("startedAt") or running.get("startedAt"))
            pt.storage_init_finished = parse_ts(term.get("finishedAt"))
            break

    for cs in (pod.get("status", {}).get("containerStatuses") or []):
        if cs.get("name") == "kserve-container":
            running = (cs.get("state") or {}).get("running") or {}
            term = (cs.get("state") or {}).get("terminated") or {}
            pt.kserve_started = parse_ts(running.get("startedAt") or term.get("startedAt"))
            break

    # Image pull events for this pod
    events = kubectl_json(
        "get", "events", "-n", NS,
        "--field-selector", f"involvedObject.name={pt.name}",
    )
    pulls_started: list[dt.datetime] = []
    pulls_finished: list[tuple[dt.datetime, str]] = []
    for ev in events.get("items", []):
        ts = parse_ts(ev.get("firstTimestamp") or ev.get("eventTime"))
        if ts is None:
            continue
        reason = ev.get("reason", "")
        msg = ev.get("message", "") or ""
        if reason == "Pulling" and "kserve-container" in msg:
            pulls_started.append(ts)
        elif reason == "Pulled" and "kserve-container" in msg:
            pulls_finished.append((ts, msg))
    # Fall back to any Pulling/Pulled if we couldn't isolate kserve-container.
    if not pulls_started:
        pulls_started = [
            parse_ts(ev.get("firstTimestamp")) for ev in events.get("items", [])
            if ev.get("reason") == "Pulling" and parse_ts(ev.get("firstTimestamp"))
        ]
    if not pulls_finished:
        pulls_finished = [
            (parse_ts(ev.get("firstTimestamp")), ev.get("message", "") or "")
            for ev in events.get("items", [])
            if ev.get("reason") == "Pulled" and parse_ts(ev.get("firstTimestamp"))
        ]
    if pulls_started:
        pt.image_pull_started = min(pulls_started)
    if pulls_finished:
        pulls_finished.sort(key=lambda x: x[0])
        pt.image_pull_finished, pt.image_pull_event_text = pulls_finished[-1]

    return pt


def extract_node_timeline(node: dict) -> NodeTimeline:
    nt = NodeTimeline()
    nt.name = node["metadata"]["name"]
    nt.created = parse_ts(node["metadata"].get("creationTimestamp"))
    nt.ready = first_condition_time(node, "Ready")

    # Find the device-plugin pod scheduled on this node and use *its* Ready
    # condition as a proxy for "GPU is now schedulable on this node".
    dp = kubectl_json("get", "pod", "-A", "-l", DEVICE_PLUGIN_LABEL)
    for p in dp.get("items", []):
        if p.get("spec", {}).get("nodeName") == nt.name:
            nt.device_plugin_ready = first_condition_time(p, "Ready")
            break
    return nt


# ---------------------------------------------------------------------------
# Pre-flight cold-state helpers
# ---------------------------------------------------------------------------
def force_cold_start() -> None:
    print("--- --force-cold: deleting existing pods ---")
    run(["kubectl", "delete", "pod", "-n", NS, "-l", LABEL, "--wait=false"], check=False)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if not list_pod_uids():
            return
        time.sleep(2)


def wait_for_zero(seconds: int) -> None:
    print(f"--- --wait-zero: waiting up to {seconds}s for Knative to scale to 0 ---")
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not list_pod_uids():
            return
        time.sleep(5)


# ---------------------------------------------------------------------------
# Diagnostics — collect errors from k8s to explain failures
# ---------------------------------------------------------------------------
def collect_diagnostics() -> list[str]:
    """Gather warning events and failing conditions from the InferenceService
    and its pods. Returns a list of one-line diagnostic strings."""
    diags: list[str] = []

    # InferenceService conditions with status != True
    isvc = kubectl_json("get", "inferenceservice", ISVC, "-n", NS)
    for c in (isvc.get("status", {}) or {}).get("conditions", []) or []:
        if c.get("status") != "True":
            msg = c.get("message", "") or ""
            diags.append(f"[ISVC {c.get('type', '?')}] {msg}")

    # Warning events in the namespace (pod scheduling failures, webhook denials, etc.)
    events = kubectl_json("get", "events", "-n", NS,
                          "--field-selector", "type=Warning")
    seen: set[str] = set()
    for ev in events.get("items", []):
        reason = ev.get("reason", "")
        msg = (ev.get("message", "") or "").strip()
        key = f"{reason}:{msg}"
        if key in seen:
            continue
        seen.add(key)
        obj_name = ev.get("involvedObject", {}).get("name", "")
        diags.append(f"[{reason}] {obj_name}: {msg}")

    return diags


# ---------------------------------------------------------------------------
# Reporting (rich)
# ---------------------------------------------------------------------------
def fmt_delta_text(secs: float | None, *, color: bool = True) -> Text:
    """Format a duration as a Rich Text. With color=True, applies a heatmap
    so slow steps stand out: red ≥ 60s, yellow ≥ 10s, green ≥ 1s."""
    if secs is None:
        return Text("—", style="dim")
    text = fmt_delta(secs).strip()
    if not color:
        return Text(text)
    if secs >= 60:
        style = "bold red"
    elif secs >= 10:
        style = "yellow"
    elif secs >= 1:
        style = "green"
    else:
        style = "dim green"
    return Text(text, style=style)


def _new_timeline_table(title: str | Text) -> Table:
    t = Table(
        title=title,
        title_justify="left",
        title_style="bold cyan",
        box=box.SIMPLE_HEAD,
        show_header=True,
        header_style="bold",
        padding=(0, 1),
        expand=False,
    )
    t.add_column("Phase", no_wrap=True)
    t.add_column("Absolute time", no_wrap=True)
    t.add_column("Δ from t0", justify="right")
    t.add_column("Step Δ", justify="right")
    return t


def _new_phase_table(title: str) -> Table:
    t = Table(
        title=title,
        title_justify="left",
        title_style="bold cyan",
        box=box.SIMPLE_HEAD,
        show_header=True,
        header_style="bold",
        padding=(0, 1),
        expand=False,
    )
    t.add_column("Phase", no_wrap=True)
    t.add_column("Duration", justify="right")
    return t


class Stepper:
    """Adds rows to a Rich timeline Table while tracking the previous
    timestamp so the 'Step Δ' column shows duration since the prior step
    within the same section. Call .reset() between sections so deltas do not
    span unrelated phases (e.g. node → pod)."""

    def __init__(self, t0: dt.datetime) -> None:
        self.t0 = t0
        self.prev: dt.datetime | None = None

    def reset(self) -> None:
        self.prev = None

    def row(self, table: Table, label: str, ts: dt.datetime | None) -> None:
        if ts is None:
            dash = Text("—", style="dim")
            table.add_row(label, dash, dash, dash)
            return
        abs_str = ts.strftime("%H:%M:%SZ")
        d_t0 = delta(self.t0, ts)
        step = (ts - self.prev).total_seconds() if self.prev else None
        table.add_row(
            label,
            abs_str,
            fmt_delta_text(d_t0, color=False),
            fmt_delta_text(step),
        )
        self.prev = ts


def report(t0: dt.datetime, t1: dt.datetime, http_res: HttpResult,
           primary_pod: PodTimeline | None,
           other_new_pods: list[PodTimeline],
           nodes: list[NodeTimeline]) -> None:
    console.print()
    status_color = "green" if http_res.http_code == "200" else "red"
    console.print(Panel.fit(
        f"[bold]GPU cold-start timeline[/bold]   (Δ relative to t0 = request sent)\n"
        f"t0:   {t0.strftime('%Y-%m-%dT%H:%M:%S.%fZ')[:-4]}Z\n"
        f"t1:   {t1.strftime('%Y-%m-%dT%H:%M:%S.%fZ')[:-4]}Z\n"
        f"HTTP: [{status_color}]{http_res.http_code or '—'}[/{status_color}]",
        border_style="cyan",
    ))

    stepper = Stepper(t0)
    all_pod_tls = ([primary_pod] if primary_pod else []) + other_new_pods

    # ------- Node provisioning (one table per new GPU node) -------
    if nodes:
        for i, node in enumerate(nodes, start=1):
            suffix = f" ({i} of {len(nodes)})" if len(nodes) > 1 else ""
            hosted = [p.name for p in all_pod_tls if p and p.node == node.name]
            host_str = f" — hosts: {', '.join(hosted)}" if hosted else ""
            title = Text.from_markup(
                f"Node provisioning{suffix}: [cyan]{node.name}[/cyan]"
                f"[dim]{host_str}[/dim]"
            )
            tbl = _new_timeline_table(title)
            stepper.reset()
            stepper.row(tbl, "node object created (k8s)",  node.created)
            stepper.row(tbl, "node Ready=true",            node.ready)
            stepper.row(tbl, "nvidia device-plugin Ready", node.device_plugin_ready)
            console.print(tbl)
    else:
        console.print(
            "[dim]No new GPU node was provisioned (used existing capacity).[/dim]"
        )

    # ------- Primary pod lifecycle -------
    if primary_pod:
        title = Text.from_markup(
            f"Pod lifecycle: [cyan]{primary_pod.name}[/cyan] "
            f"on [cyan]{primary_pod.node or '?'}[/cyan]"
        )
        tbl = _new_timeline_table(title)
        stepper.reset()
        stepper.row(tbl, "pod created",                  primary_pod.created)
        stepper.row(tbl, "PodScheduled=true",            primary_pod.pod_scheduled)
        stepper.row(tbl, "image pull started",           primary_pod.image_pull_started)
        stepper.row(tbl, "image pull finished",          primary_pod.image_pull_finished)
        stepper.row(tbl, "storage-initializer started",  primary_pod.storage_init_started)
        stepper.row(tbl, "storage-initializer finished", primary_pod.storage_init_finished)
        stepper.row(tbl, "Initialized=true",             primary_pod.initialized)
        stepper.row(tbl, "kserve-container started",     primary_pod.kserve_started)
        stepper.row(tbl, "ContainersReady=true (vLLM)",  primary_pod.containers_ready)
        stepper.row(tbl, "Pod Ready=true",               primary_pod.ready)
        console.print(tbl)
    else:
        console.print(
            "[yellow]No pod found — request may have hit an existing "
            "replica or failed early.[/yellow]"
        )

    # ------- Other new pods (short summary) -------
    if other_new_pods:
        tbl = Table(
            title=f"Additional new pods ({len(other_new_pods)})",
            title_justify="left", title_style="bold cyan",
            box=box.SIMPLE_HEAD, show_header=True, header_style="bold",
            padding=(0, 1), expand=False,
        )
        tbl.add_column("Pod", no_wrap=True)
        tbl.add_column("Node", no_wrap=True)
        tbl.add_column("Created")
        tbl.add_column("Ready")
        for p in other_new_pods:
            created = p.created.strftime("%H:%M:%S") if p.created else "—"
            ready: str | Text = (
                p.ready.strftime("%H:%M:%S") if p.ready
                else Text("not ready", style="yellow")
            )
            tbl.add_row(p.name, p.node or "?", created, ready)
        console.print(tbl)

    # ------- HTTP timing -------
    htbl = _new_phase_table("HTTP timing")
    htbl.add_row("time to first byte (TTFB)", fmt_delta_text(http_res.ttfb))
    htbl.add_row("total response time",       fmt_delta_text(http_res.total))
    console.print(htbl)

    # ------- Derived phase durations (the 'improve this step' view) -------
    ptbl = _new_phase_table("Phase durations")

    # Knative autoscaler reaction: request received → pod created
    if primary_pod and primary_pod.created:
        ptbl.add_row("Knative scaler (t0 → Pod created)",
                     fmt_delta_text((primary_pod.created - t0).total_seconds()))

    # Cluster Autoscaler reaction: pod pending → new node object registered.
    # Uses the earliest new node creation time as the signal that CAS acted.
    if primary_pod and primary_pod.created and nodes:
        earliest_node = min(nodes, key=lambda n: n.created or t0)
        if earliest_node.created:
            ptbl.add_row("Cluster Autoscaler (Pod created → Node provisioned)",
                         fmt_delta_text((earliest_node.created - primary_pod.created).total_seconds()))

    for i, node in enumerate(nodes, start=1):
        # Use parens not brackets — brackets would be parsed as Rich markup.
        tag = f"  (node {i}/{len(nodes)})" if len(nodes) > 1 else ""
        if node.created and node.ready:
            ptbl.add_row(f"EC2 boot → Node Ready{tag}",
                         fmt_delta_text((node.ready - node.created).total_seconds()))
        if node.ready and node.device_plugin_ready:
            ptbl.add_row(f"Node Ready → GPU advertised{tag}",
                         fmt_delta_text((node.device_plugin_ready - node.ready).total_seconds()))
    if primary_pod:
        if primary_pod.pod_scheduled and primary_pod.image_pull_finished:
            ptbl.add_row("Scheduled → image pulled",
                         fmt_delta_text((primary_pod.image_pull_finished - primary_pod.pod_scheduled).total_seconds()))
        if primary_pod.storage_init_started and primary_pod.storage_init_finished:
            ptbl.add_row("storage-initializer (model dl)",
                         fmt_delta_text((primary_pod.storage_init_finished - primary_pod.storage_init_started).total_seconds()))
        if primary_pod.kserve_started and primary_pod.containers_ready:
            ptbl.add_row("vLLM start → ContainersReady",
                         fmt_delta_text((primary_pod.containers_ready - primary_pod.kserve_started).total_seconds()))
        if primary_pod.ready:
            ptbl.add_row("t0 → Pod Ready",
                         fmt_delta_text((primary_pod.ready - t0).total_seconds()))
    ptbl.add_row("t0 → response received",
                 fmt_delta_text((t1 - t0).total_seconds()))
    console.print(ptbl)


def _pod_dict(p: PodTimeline) -> dict[str, Any]:
    def iso(ts: dt.datetime | None) -> str | None:
        return ts.isoformat() if ts else None
    return {
        "name": p.name, "node": p.node,
        "created": iso(p.created),
        "pod_scheduled": iso(p.pod_scheduled),
        "image_pull_started": iso(p.image_pull_started),
        "image_pull_finished": iso(p.image_pull_finished),
        "storage_init_started": iso(p.storage_init_started),
        "storage_init_finished": iso(p.storage_init_finished),
        "initialized": iso(p.initialized),
        "kserve_started": iso(p.kserve_started),
        "containers_ready": iso(p.containers_ready),
        "ready": iso(p.ready),
    }


def _node_dict(n: NodeTimeline) -> dict[str, Any]:
    def iso(ts: dt.datetime | None) -> str | None:
        return ts.isoformat() if ts else None
    return {
        "name": n.name,
        "created": iso(n.created),
        "ready": iso(n.ready),
        "device_plugin_ready": iso(n.device_plugin_ready),
    }


def write_result_json(t0: dt.datetime, t1: dt.datetime, http_res: HttpResult,
                      primary_pod: PodTimeline | None,
                      other_new_pods: list[PodTimeline],
                      nodes: list[NodeTimeline]) -> None:
    def iso(ts: dt.datetime | None) -> str | None:
        return ts.isoformat() if ts else None

    out: dict[str, Any] = {
        "t0": iso(t0),
        "t1": iso(t1),
        "http_status": http_res.http_code,
        "error": http_res.error,
        "ttfb_seconds": http_res.ttfb,
        "total_seconds": http_res.total,
        "primary_pod": _pod_dict(primary_pod) if primary_pod else None,
        "other_new_pods": [_pod_dict(p) for p in other_new_pods],
        "new_nodes": [_node_dict(n) for n in nodes],
    }
    RESULT_JSON.write_text(json.dumps(out, indent=2))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force-cold", action="store_true",
                    help="delete existing pods to force a true cold start")
    ap.add_argument("--wait-zero", type=int, default=0, metavar="SECONDS",
                    help="wait up to N seconds for Knative to scale to 0 first")
    args = ap.parse_args()

    require_binaries("kubectl", "terraform")

    url = get_terraform_url()
    console.rule("[bold]KServe GPU cold-start measurement[/bold]")
    console.print(f"URL:       [cyan]{url}[/cyan]")
    console.print(f"Namespace: {NS}")
    console.print(f"Service:   {ISVC}")
    console.print()

    existing = list_pod_uids()
    console.print(f"Existing {ISVC} pods: {len(existing)}")

    if args.force_cold and existing:
        force_cold_start()
        existing = list_pod_uids()
    elif args.wait_zero > 0 and existing:
        wait_for_zero(args.wait_zero)
        existing = list_pod_uids()

    if existing:
        console.print(
            f"[yellow]WARNING:[/yellow] {len(existing)} {ISVC} pod(s) already "
            "running. Cold-start phases may be partial. Use [cyan]--force-cold[/cyan] "
            "or [cyan]--wait-zero N[/cyan]."
        )
        console.print()

    baseline_pods = list_pod_uids()
    baseline_nodes = list_node_uids()
    console.print(f"Baseline inference (GPU-capable) nodes: {len(baseline_nodes)}")
    console.print()

    watcher = Watcher()
    watcher.start()

    # Fire the request in a background thread so we can update the status
    # line with a live elapsed-time counter.
    request_result: list[tuple[dt.datetime, dt.datetime, HttpResult]] = []
    request_error: list[BaseException] = []

    def _do_request() -> None:
        try:
            request_result.append(fire_request(url))
        except BaseException as exc:
            request_error.append(exc)

    req_thread = threading.Thread(target=_do_request, daemon=True)
    start_mono = time.monotonic()
    req_thread.start()

    with console.status("", spinner="dots") as status:
        while req_thread.is_alive():
            elapsed = time.monotonic() - start_mono
            status.update(
                f"[cyan]Sending request[/cyan] — "
                f"{elapsed:5.1f}s elapsed (max {REQUEST_TIMEOUT}s)…"
            )
            req_thread.join(timeout=0.5)

    watcher.stop()
    watcher.join(timeout=2)

    if request_error:
        raise request_error[0]
    t0, t1, http_res = request_result[0]

    status_color = "green" if http_res.http_code == "200" else "red"
    total_wall = (t1 - t0).total_seconds()
    console.print(
        f"Got HTTP [{status_color}]{http_res.http_code or '—'}[/{status_color}] "
        f"in {fmt_delta(total_wall).strip()}"
    )

    console.print("[dim]Collecting authoritative timestamps from kubectl…[/dim]")
    primary_pod_obj = pick_primary_pod(baseline_pods)
    primary_pod_tl = extract_pod_timeline(primary_pod_obj) if primary_pod_obj else None

    # Any *other* new pods (e.g. a second revision briefly co-existing)
    new_pod_objs = pick_new_pods(baseline_pods)
    primary_uid = primary_pod_obj["metadata"]["uid"] if primary_pod_obj else None
    other_new_pods = [
        extract_pod_timeline(p) for p in new_pod_objs
        if p["metadata"]["uid"] != primary_uid
    ]

    # All new GPU nodes — cluster-autoscaler often provisions more than one.
    new_node_objs = pick_new_nodes(baseline_nodes)
    node_tls = [extract_node_timeline(n) for n in new_node_objs]

    if len(node_tls) > 1:
        console.print(
            f"[yellow]NOTE:[/yellow] {len(node_tls)} new GPU nodes were provisioned"
        )
    if other_new_pods:
        console.print(
            f"[yellow]NOTE:[/yellow] {len(other_new_pods) + 1} new pods appeared "
            f"(primary + {len(other_new_pods)} other)"
        )

    report(t0, t1, http_res, primary_pod_tl, other_new_pods, node_tls)
    write_result_json(t0, t1, http_res, primary_pod_tl, other_new_pods, node_tls)

    body_preview = ""
    if RESPONSE_FILE.exists():
        text = RESPONSE_FILE.read_text(errors="replace")
        try:
            body_preview = json.dumps(json.loads(text))[:500]
        except json.JSONDecodeError:
            body_preview = text[:500]

    console.print()
    console.print(Panel(body_preview, title="Response body (truncated)",
                        border_style="dim", expand=False))

    artefacts = Table(title="Artefacts", title_justify="left",
                      title_style="bold cyan", box=box.SIMPLE_HEAD,
                      show_header=False, padding=(0, 1), expand=False)
    artefacts.add_column("kind"); artefacts.add_column("path")
    artefacts.add_row("full response", str(RESPONSE_FILE))
    artefacts.add_row("watch log",     str(WATCH_LOG))
    artefacts.add_row("parsed JSON",   str(RESULT_JSON))
    console.print(artefacts)

    ok = (http_res.http_code == "200") and ('"choices"' in body_preview)
    gpu_nodes = len(node_tls)
    if gpu_nodes > 1:
        node_info = f" [bold red]({gpu_nodes} GPU nodes provisioned)[/bold red]"
    elif gpu_nodes == 1:
        node_info = " [bold green](1 GPU node provisioned)[/bold green]"
    else:
        node_info = " [dim](no new GPU node)[/dim]"
    if ok:
        console.print(f"[bold green]PASS[/bold green]{node_info}")
    else:
        console.print(
            f"[bold red]FAIL[/bold red] (http={http_res.http_code}){node_info}"
        )
        # Collect and display diagnostics to help identify the root cause
        diags = collect_diagnostics()
        if diags:
            dtbl = Table(
                title="Diagnostics (warnings & errors from k8s)",
                title_justify="left", title_style="bold red",
                box=box.SIMPLE_HEAD, show_header=False,
                padding=(0, 1), expand=False,
            )
            dtbl.add_column("Issue", style="yellow")
            for d in diags:
                dtbl.add_row(d)
            console.print(dtbl)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
