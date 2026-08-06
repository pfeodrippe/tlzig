#!/usr/bin/env python3
"""Paired Java TLC/tlzig correctness audit for checked-in model configs."""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPORA = (
    "specs",
    "vendor/tlaplus-examples/specifications",
    "vendor/MDBTLA",
)
TLC_JAR = ROOT / "vendor/tlaplus/tlatools/org.lamport.tlatools/dist/tla2tools.jar"
COMMUNITY_JAR = ROOT / "vendor/tlaplus/tlatools/org.lamport.tlatools/lib/CommunityModules.jar"
TLZIG = ROOT / "zig-out/bin/tlzig"
COUNT_RE = re.compile(r"([\d,]+) states generated, ([\d,]+) distinct states found")
TLZIG_COUNT_RE = re.compile(r"generated=(\d+) distinct=(\d+)")
SIMULATION_DEPTH = 100
SIMULATION_SEED = 0x544C5A49475F5349
SIMULATION_MAX_STATES = 1_000_000
TLC_FINGERPRINT_INDEX = 0
TLC_MODEL_CHECK_SEED = 0

# Local cfgs exercise upstream modules without copying the TLA+ source.
LOCAL_CONFIG_MODULES = {
    "specs/APMajority.cfg": "vendor/tlaplus-examples/specifications/Majority/APMajority.tla",
    "specs/AsynchInterface_simple.cfg": "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/AsynchInterface.tla",
    "specs/Barrier_simple.cfg": "vendor/tlaplus-examples/specifications/barriers/Barrier.tla",
    "specs/Channel_simple.cfg": "vendor/tlaplus-examples/specifications/SpecifyingSystems/AsynchronousInterface/Channel.tla",
    "specs/DieHard_no_inv.cfg": "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla",
    "specs/DieHard_not_solved.cfg": "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla",
    "specs/DieHard_simple.cfg": "vendor/tlaplus-examples/specifications/DieHard/DieHard.tla",
    "specs/FindHighest_simple.cfg": "vendor/tlaplus-examples/specifications/LearnProofs/FindHighest.tla",
    "specs/HourClock_simple.cfg": "vendor/tlaplus-examples/specifications/SpecifyingSystems/HourClock/HourClock.tla",
    "specs/MCEcho.cfg": "vendor/tlaplus-examples/specifications/echo/MCEcho.tla",
    "specs/MCTwoPhase.cfg": "vendor/tlaplus-examples/specifications/TwoPhase/MCTwoPhase.tla",
    "specs/Majority_simple.cfg": "vendor/tlaplus-examples/specifications/Majority/Majority.tla",
    "specs/Majority_spec.cfg": "vendor/tlaplus-examples/specifications/Majority/Majority.tla",
    "specs/MissionariesAndCannibals_typeok.cfg": "vendor/tlaplus-examples/specifications/MissionariesAndCannibals/MissionariesAndCannibals.tla",
    "specs/SimpleRegular_pcorrect.cfg": "vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular.tla",
    "specs/SimpleRegular_simple.cfg": "vendor/tlaplus-examples/specifications/TeachingConcurrency/SimpleRegular.tla",
    "specs/Simple_pcorrect.cfg": "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla",
    "specs/Simple_simple.cfg": "vendor/tlaplus-examples/specifications/TeachingConcurrency/Simple.tla",
}

MDBTLA_CONFIG_MODULES = {
    "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn_rc_local.cfg": "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block.cfg": "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_no_prepare_block_or_ww.cfg": "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_snapshot.cfg": "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    "vendor/MDBTLA/MultiShardTxn/models/MCMultiShardTxn_RC_with_prepare_block.cfg": "vendor/MDBTLA/MultiShardTxn/MCMultiShardTxn.tla",
    "vendor/MDBTLA/MultiShardTxn/models/MultiShardTxn_RC.cfg": "vendor/MDBTLA/MultiShardTxn/MultiShardTxn.tla",
}

# These cfgs are executable Toolbox/CI utilities, not state-space models. They
# have no INIT/NEXT/SPECIFICATION and perform expensive top-level expression or
# subprocess work instead. Keep them visible in the manifest without treating
# their side effects as model-checking coverage.
NON_MODEL_HARNESSES = {
    "vendor/tlaplus-examples/specifications/CarTalkPuzzle/CarTalkPuzzle.toolbox/Model_3/MC.cfg": (
        "evaluates and prints the combinatorial AllSolutions expression"
    ),
    "vendor/tlaplus-examples/specifications/ewd998/SmokeEWD998_SC.cfg": (
        "spawns nested TLC simulations and writes statistical CSV output"
    ),
}


@dataclasses.dataclass(frozen=True)
class Run:
    status: str
    outcome: str
    generated: int | None
    distinct: int | None
    seconds: float
    detail: str


def excluded(path: Path) -> bool:
    text = str(path).lower()
    return any(part in text for part in ("/tlaps/", "_proof.", "_ttrace_"))


def discover(corpora: list[str]) -> list[Path]:
    configs: list[Path] = []
    for corpus in corpora:
        root = ROOT / corpus
        configs.extend(path for path in root.rglob("*.cfg") if not excluded(path))
    return sorted(set(configs))


def manifest_models() -> tuple[dict[str, str], dict[str, int]]:
    root = ROOT / "vendor/tlaplus-examples"
    mappings: dict[str, str] = {}
    simulations: dict[str, int] = {}
    for manifest in root.rglob("manifest.json"):
        try:
            contents = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        for module in contents.get("modules", []):
            tla = root / module["path"]
            for model in module.get("models", []):
                cfg = root / model["path"]
                relative = str(cfg.relative_to(ROOT))
                mappings[relative] = str(tla.relative_to(ROOT))
                mode = model.get("mode")
                if isinstance(mode, dict) and "simulate" in mode:
                    simulations[relative] = int(mode["simulate"]["traceCount"])
    return mappings, simulations


MANIFEST_CONFIG_MODULES, MANIFEST_SIMULATION_MODELS = manifest_models()


def candidate_modules(cfg: Path) -> list[Path]:
    relative = str(cfg.relative_to(ROOT))
    configured = (
        LOCAL_CONFIG_MODULES.get(relative)
        or MDBTLA_CONFIG_MODULES.get(relative)
        or MANIFEST_CONFIG_MODULES.get(relative)
    )
    if configured is not None:
        return [ROOT / configured]

    # The two tcp configs missing from the examples manifest share one root.
    if relative.endswith("/tcp/IndInv_apa_init.cfg"):
        return [cfg.with_name("IndInv_apa.tla")]

    same = cfg.with_suffix(".tla")
    if same.exists():
        return [same]
    return []


def summarize_detail(output: str) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    interesting = [
        line
        for line in lines
        if "Error:" in line
        or "error." in line
        or "Exception" in line
        or "not supported" in line
        or "not found" in line
    ]
    selected = interesting[-1:] or lines[-1:]
    return " ".join(selected)[:500]


def last_counts(output: str, pattern: re.Pattern[str]) -> tuple[int | None, int | None]:
    matches = list(pattern.finditer(output))
    if not matches:
        return None, None
    match = matches[-1]
    return tuple(int(value.replace(",", "")) for value in match.groups())  # type: ignore[return-value]


def classify_tlc(returncode: int | None, output: str, seconds: float) -> Run:
    generated, distinct = last_counts(output, COUNT_RE)
    if "ran out of memory" in output or "OutOfMemoryError" in output:
        return Run(
            "valid-resource-limit",
            "resource-limit",
            generated,
            distinct,
            seconds,
            summarize_detail(output),
        )
    explored = generated is not None or any(
        marker in output
        for marker in (
            "Computing initial states",
            "Finished computing initial states",
            "Model checking completed",
        )
    )
    if returncode is None:
        status = "valid-timeout" if explored else "resolution-timeout"
        return Run(status, "timeout", generated, distinct, seconds, summarize_detail(output))
    if any(
        marker in output
        for marker in (
            "The error occurred when TLC was evaluating",
            "Error: Evaluating",
            "TLC encountered the following error",
        )
    ):
        return Run("invalid-evaluation", "rejected", generated, distinct, seconds, summarize_detail(output))
    if not explored:
        return Run("invalid", "rejected", generated, distinct, seconds, summarize_detail(output))
    if "Deadlock reached" in output:
        outcome = "deadlock"
    elif any(
        marker in output
        for marker in (
            "Invariant " ,
            "Temporal properties were violated",
            "is violated.",
        )
    ):
        outcome = "violation"
    elif returncode != 0:
        return Run("invalid", "rejected", generated, distinct, seconds, summarize_detail(output))
    else:
        outcome = "completed"
    return Run("valid", outcome, generated, distinct, seconds, summarize_detail(output))


def run_process(argv: list[str], cwd: Path, timeout: int) -> tuple[int | None, str, float]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        )
        return completed.returncode, completed.stdout, time.monotonic() - started
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return None, output, time.monotonic() - started


def run_tlc(
    cfg: Path,
    tla: Path,
    timeout: int,
    workers: str,
    xmx: str,
    simulation_trace_count: int | None = None,
) -> Run:
    classpath = os.pathsep.join((str(TLC_JAR), str(COMMUNITY_JAR), str(ROOT / "specs/modules")))
    with tempfile.TemporaryDirectory(prefix="tlzig-tlc-audit-") as metadir:
        java_options = (
            ["-XX:ActiveProcessorCount=1", "-XX:+UseSerialGC"]
            if workers == "1"
            else ["-XX:+UseParallelGC"]
        )
        mode_options = (
            [
                "-simulate",
                f"num={simulation_trace_count}",
                "-depth",
                str(SIMULATION_DEPTH),
                "-seed",
                str(SIMULATION_SEED),
            ]
            if simulation_trace_count is not None
            else ["-seed", str(TLC_MODEL_CHECK_SEED)]
        )
        argv = ["java", *java_options,
            f"-Xmx{xmx}",
            "-cp",
            classpath,
            "-Dtlc2.tool.impl.Tool.cdot=true",
            "tlc2.TLC",
            "-fp",
            str(TLC_FINGERPRINT_INDEX),
            "-metadir",
            metadir,
            "-workers",
            workers,
            "-cleanup",
            "-lncheck",
            "final",
            *mode_options,
            "-config",
            str(cfg),
            str(tla),
        ]
        returncode, output, seconds = run_process(argv, ROOT, timeout)
    return classify_tlc(returncode, output, seconds)


def classify_tlzig(returncode: int | None, output: str, seconds: float) -> Run:
    generated, distinct = last_counts(output, TLZIG_COUNT_RE)
    if returncode is None:
        return Run("timeout", "timeout", generated, distinct, seconds, summarize_detail(output))
    if "StateSpaceExhausted" in output:
        return Run("bounded", "bounded", generated, distinct, seconds, summarize_detail(output))
    if "CanonicalStorageExhausted" in output:
        return Run(
            "bounded",
            "resource-bounded",
            generated,
            distinct,
            seconds,
            summarize_detail(output),
        )
    if "Deadlock" in output:
        outcome = "deadlock"
    elif "InvariantViolated" in output or "PropertyViolated" in output:
        outcome = "violation"
    elif returncode == 0:
        outcome = "completed"
    else:
        error_match = re.findall(r"error\.([A-Za-z0-9_]+)", output)
        detail = error_match[-1] if error_match else summarize_detail(output)
        return Run("gap", "rejected", generated, distinct, seconds, detail)
    return Run("valid", outcome, generated, distinct, seconds, summarize_detail(output))


def run_tlzig(
    cfg: Path,
    tla: Path,
    timeout: int,
    max_states: int,
    max_successors: int,
    state_values_per_state: int,
    arena_bytes: int,
    eval_arena_bytes: int,
    workers: str,
    simulation_trace_count: int | None = None,
) -> Run:
    effective_max_states = (
        max(max_states, SIMULATION_MAX_STATES)
        if simulation_trace_count is not None
        else max_states
    )
    argv = [
        str(TLZIG),
        "--spec",
        str(tla),
        "--cfg",
        str(cfg),
        "--workers",
        workers,
        "--max-states",
        str(effective_max_states),
        "--max-successors",
        str(max_successors),
        "--state-values-per-state",
        str(state_values_per_state),
        "--unlimited-memory",
        "--arena-bytes",
        str(arena_bytes),
        "--eval-arena-bytes",
        str(eval_arena_bytes),
    ]
    if simulation_trace_count is not None:
        argv.extend((
            "--simulate-traces",
            str(simulation_trace_count),
            "--simulate-depth",
            str(SIMULATION_DEPTH),
            "--seed",
            str(SIMULATION_SEED),
        ))
    returncode, output, seconds = run_process(argv, ROOT, timeout)
    return classify_tlzig(returncode, output, seconds)


def compare_runs(tlc: Run, tlzig: Run, stochastic: bool) -> str:
    # A TLC timeout establishes that the model was accepted, so a deterministic
    # tlzig rejection is still a hard gap and must not be hidden as "bounded".
    if tlzig.status == "gap":
        return "gap"
    if tlc.status in {"valid-timeout", "valid-resource-limit"} or \
            tlzig.status in {"timeout", "bounded"}:
        return "bounded"
    if tlzig.status != "valid":
        return "gap"
    if tlc.outcome != tlzig.outcome:
        return "outcome-mismatch"
    # A counterexample/deadlock run stops at the first witness. Enumeration
    # order and worker scheduling make those partial counts non-semantic; keep
    # both raw counts in the manifest, but compare the witnessed outcome.
    if tlc.outcome in {"violation", "deadlock"}:
        return "outcome-exact"
    # TLC!RandomElement intentionally samples a value. Independent unseeded
    # executions can explore different concrete models, so retain their raw
    # counts but compare only successful outcomes.
    if stochastic:
        return "stochastic-outcome"
    if tlc.distinct is not None and tlzig.distinct is not None and tlc.distinct != tlzig.distinct:
        return "count-mismatch"
    return "exact"


def resolve_and_run(
    cfg: Path,
    timeout: int,
    resolve_timeout: int,
    max_states: int,
    max_successors: int,
    state_values_per_state: int,
    arena_bytes: int,
    eval_arena_bytes: int,
    tlc_workers: str,
    tlc_xmx: str,
    tlzig_workers: str,
) -> dict[str, object]:
    relative = str(cfg.relative_to(ROOT))
    harness_reason = NON_MODEL_HARNESSES.get(relative)
    if harness_reason is not None:
        candidates = candidate_modules(cfg)
        return {
            "cfg": relative,
            "tla": str(candidates[0].relative_to(ROOT)) if candidates else None,
            "tlc": {"status": "not-model", "detail": harness_reason},
            "tlzig": None,
            "parity": "non-model-harness",
        }
    candidates = candidate_modules(cfg)
    simulation_trace_count = MANIFEST_SIMULATION_MODELS.get(relative)
    rejected: list[str] = []
    last_tlc: Run | None = None
    for candidate in candidates:
        candidate_timeout = (
            timeout
            if len(candidates) == 1 or candidate == cfg.with_suffix(".tla")
            else resolve_timeout
        )
        tlc = run_tlc(
            cfg,
            candidate,
            candidate_timeout,
            tlc_workers,
            tlc_xmx,
            simulation_trace_count,
        )
        last_tlc = tlc
        if tlc.status.startswith("invalid"):
            rejected.append(f"{candidate.name}: {tlc.detail}")
            continue
        if tlc.status == "resolution-timeout":
            rejected.append(f"{candidate.name}: resolution timeout")
            continue
        if simulation_trace_count is not None:
            tlzig = run_tlzig(
                cfg,
                candidate,
                timeout,
                max_states,
                max_successors,
                state_values_per_state,
                arena_bytes,
                eval_arena_bytes,
                tlzig_workers,
                simulation_trace_count,
            )
            parity = compare_runs(tlc, tlzig, True)
            return {
                "cfg": relative,
                "tla": str(candidate.relative_to(ROOT)),
                "tlc": dataclasses.asdict(tlc),
                "tlzig": dataclasses.asdict(tlzig),
                "mode": {"simulate": {"traceCount": simulation_trace_count}},
                "workers": {"tlc": tlc_workers, "tlzig": tlzig_workers},
                "parity": parity,
            }
        tlzig = run_tlzig(
            cfg,
            candidate,
            timeout,
            max_states,
            max_successors,
            state_values_per_state,
            arena_bytes,
            eval_arena_bytes,
            tlzig_workers,
        )
        stochastic = "RandomElement" in candidate.read_text(errors="replace")
        parity = compare_runs(tlc, tlzig, stochastic)
        return {
            "cfg": str(cfg.relative_to(ROOT)),
            "tla": str(candidate.relative_to(ROOT)),
            "tlc": dataclasses.asdict(tlc),
            "tlzig": dataclasses.asdict(tlzig),
            "workers": {"tlc": tlc_workers, "tlzig": tlzig_workers},
            "parity": parity,
        }
    if candidates and last_tlc is not None and last_tlc.status.startswith("invalid"):
        return {
            "cfg": str(cfg.relative_to(ROOT)),
            "tla": str(candidates[-1].relative_to(ROOT)),
            "tlc": dataclasses.asdict(last_tlc),
            "tlzig": None,
            "parity": "tlc-invalid",
        }
    return {
        "cfg": str(cfg.relative_to(ROOT)),
        "tla": None,
        "tlc": {"status": "unresolved", "detail": " | ".join(rejected[-3:])},
        "tlzig": None,
        "parity": "unresolved-root",
    }


def load_completed(
    path: Path,
    active_cfgs: set[str],
    retry_bounded: bool,
) -> dict[str, dict[str, object]]:
    if not path.exists():
        return {}
    rows: dict[str, dict[str, object]] = {}
    for line in path.read_text().splitlines():
        if line.strip():
            row = json.loads(line)
            cfg_key = str(row["cfg"])
            if cfg_key not in active_cfgs:
                rows[cfg_key] = row
                continue
            harness_reason = NON_MODEL_HARNESSES.get(str(row["cfg"]))
            if harness_reason is not None:
                row["tlc"] = {"status": "not-model", "detail": harness_reason}
                row["tlzig"] = None
                row["parity"] = "non-model-harness"
                rows[str(row["cfg"])] = row
                continue
            if str(row["cfg"]) in MANIFEST_SIMULATION_MODELS:
                # Older audits ran these models exhaustively, which is not the
                # mode declared by the examples corpus. Re-run them correctly.
                continue
            tlc_data = row.get("tlc")
            tlzig_data = row.get("tlzig")
            if (
                isinstance(tlc_data, dict)
                and isinstance(tlzig_data, dict)
                and set(Run.__dataclass_fields__) <= set(tlc_data)
                and set(Run.__dataclass_fields__) <= set(tlzig_data)
            ):
                tla_path = row.get("tla")
                stochastic = False
                if isinstance(tla_path, str):
                    source_path = ROOT / tla_path
                    stochastic = source_path.exists() and \
                        "RandomElement" in source_path.read_text(errors="replace")
                row["parity"] = compare_runs(
                    Run(**tlc_data),
                    Run(**tlzig_data),
                    stochastic,
                )
            if row.get("parity") in {
                "gap",
                "count-mismatch",
                "outcome-mismatch",
                "unresolved-root",
            }:
                continue
            if retry_bounded and row.get("parity") == "bounded":
                continue
            rows[str(row["cfg"])] = row
    return rows


def append_row(path: Path, row: dict[str, object]) -> None:
    with path.open("a") as output:
        output.write(json.dumps(row, sort_keys=True) + "\n")
        output.flush()


def rewrite_rows(path: Path, rows: list[dict[str, object]]) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as output:
        temporary = Path(output.name)
        for row in sorted(rows, key=lambda item: str(item["cfg"])):
            output.write(json.dumps(row, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def print_summary(rows: list[dict[str, object]]) -> None:
    counts: dict[str, int] = {}
    for row in rows:
        parity = str(row["parity"])
        counts[parity] = counts.get(parity, 0) + 1
    print("summary " + " ".join(f"{key}={counts[key]}" for key in sorted(counts)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", action="append", dest="corpora")
    parser.add_argument("--filter")
    parser.add_argument(
        "--jobs",
        type=int,
        default=1,
        help=(
            "number of independent cfg audits; defaults to one because each "
            "engine run uses all cores"
        ),
    )
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--resolve-timeout", type=int, default=10)
    parser.add_argument("--max-states", type=int, default=200_000)
    parser.add_argument("--max-successors", type=int, default=65_536)
    parser.add_argument(
        "--state-values-per-state",
        type=int,
        default=160,
        help=(
            "canonical Value budget per state; --arena-bytes must also be "
            "large enough because canonical values use at most half the arena"
        ),
    )
    parser.add_argument("--arena-bytes", type=int, default=1_073_741_824)
    parser.add_argument("--eval-arena-bytes", type=int, default=1_073_741_824)
    parser.add_argument("--tlc-workers", default="auto")
    parser.add_argument("--tlc-xmx", default="1536m")
    parser.add_argument("--tlzig-workers", default="auto")
    parser.add_argument("--output", type=Path, default=ROOT / "coverage_results/primary.jsonl")
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument(
        "--retry-bounded",
        action="store_true",
        help="rerun rows previously classified as bounded",
    )
    args = parser.parse_args()

    if not TLC_JAR.exists() or not TLZIG.exists():
        parser.error("build tlzig and the TLC jar before running the audit")
    corpora = args.corpora or list(DEFAULT_CORPORA)
    configs = discover(corpora)
    if args.filter:
        configs = [cfg for cfg in configs if args.filter in str(cfg)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.fresh and args.output.exists():
        args.output.unlink()
    active_cfgs = {str(cfg.relative_to(ROOT)) for cfg in configs}
    completed = load_completed(args.output, active_cfgs, args.retry_bounded)
    pending = [cfg for cfg in configs if str(cfg.relative_to(ROOT)) not in completed]
    print(f"auditing total={len(configs)} pending={len(pending)} jobs={args.jobs}", flush=True)

    rows = list(completed.values())
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = {
            executor.submit(
                resolve_and_run,
                cfg,
                args.timeout,
                args.resolve_timeout,
                args.max_states,
                args.max_successors,
                args.state_values_per_state,
                args.arena_bytes,
                args.eval_arena_bytes,
                args.tlc_workers,
                args.tlc_xmx,
                args.tlzig_workers,
            ): cfg
            for cfg in pending
        }
        for future in concurrent.futures.as_completed(futures):
            row = future.result()
            append_row(args.output, row)
            rows.append(row)
            print(f"{row['parity']:>16} {row['cfg']} -> {row['tla']}", flush=True)
    rewrite_rows(args.output, rows)
    print_summary(rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
