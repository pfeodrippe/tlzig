#!/usr/bin/env python3
"""Compare a TLC labeled DOT graph with tlzig's canonical graph dumps."""

from __future__ import annotations

import argparse
import itertools
import multiprocessing
import os
import re
import sys
from collections import Counter, defaultdict, deque
from pathlib import Path


NODE_RE = re.compile(r'^(-?\d+) \[label="((?:\\.|[^"\\])*)"(.*)\];?$')
EDGE_RE = re.compile(
    r'^(-?\d+) -> (-?\d+) \[label="((?:\\.|[^"\\])*)"',
)
STATE_HEADER_RE = re.compile(r"^State (\d+):$")
SYMMETRY_ATOM_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
WORKER_SYMMETRY_REWRITES: tuple[dict[str, str], ...] = ()


def dot_unescape(value: str) -> str:
    result: list[str] = []
    index = 0
    escapes = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
    while index < len(value):
        if value[index] != "\\" or index + 1 == len(value):
            result.append(value[index])
            index += 1
            continue
        escaped = value[index + 1]
        replacement = escapes.get(escaped)
        if replacement is None:
            result.extend(("\\", escaped))
        else:
            result.append(replacement)
        index += 2
    return "".join(result)


def split_top_level(value: str, delimiter: str) -> list[str]:
    result: list[str] = []
    start = 0
    stack: list[str] = []
    in_string = False
    escaped = False
    pairs = {")": "(", "]": "[", "}": "{", ">": "<"}

    index = 0
    while index < len(value):
        char = value[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            index += 1
            continue
        if char in "([{":
            stack.append(char)
        elif char == "<" and index + 1 < len(value) and value[index + 1] == "<":
            stack.append("<")
            index += 1
        elif char in ")]}":
            if not stack or stack.pop() != pairs[char]:
                raise ValueError(f"unbalanced value: {value}")
        elif char == ">" and index + 1 < len(value) and value[index + 1] == ">":
            if not stack or stack.pop() != "<":
                raise ValueError(f"unbalanced tuple: {value}")
            index += 1
        elif not stack and value.startswith(delimiter, index):
            result.append(value[start:index].strip())
            index += len(delimiter)
            start = index
            continue
        index += 1
    if stack or in_string:
        raise ValueError(f"unbalanced value: {value}")
    result.append(value[start:].strip())
    return result


def matching_paren(value: str, start: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(value)):
        char = value[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unbalanced parenthesis: {value}")


def rewrite_override_functions(value: str) -> str:
    result: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(value):
        char = value[index]
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            result.append(char)
            index += 1
            continue
        if char != "(":
            result.append(char)
            index += 1
            continue

        end = matching_paren(value, index)
        inner = rewrite_override_functions(value[index + 1 : end])
        entries = split_top_level(inner, "@@")
        parsed: list[tuple[str, str]] = []
        for entry in entries:
            pair = split_top_level(entry, ":>")
            if len(pair) != 2:
                parsed = []
                break
            parsed.append((pair[0], pair[1]))
        if parsed:
            result.append("[")
            result.append(", ".join(f"{key} |-> {item}" for key, item in parsed))
            result.append("]")
        else:
            result.extend(("(", inner, ")"))
        index = end + 1
    return "".join(result)


def remove_layout_whitespace(value: str) -> str:
    result: list[str] = []
    in_string = False
    escaped = False
    for char in value:
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
            result.append(char)
        elif not char.isspace():
            result.append(char)
    return "".join(result)


def has_outer_delimiters(value: str, opening: str, closing: str) -> bool:
    if not value.startswith(opening) or not value.endswith(closing):
        return False
    if opening == "(":
        return matching_paren(value, 0) == len(value) - 1
    return True


def canonical_expression(value: str) -> str:
    value = rewrite_override_functions(value.strip())
    if has_outer_delimiters(value, "[", "]"):
        inner = value[1:-1].strip()
        if not inner:
            return "[]"
        entries: list[tuple[str, str]] = []
        for entry in split_top_level(inner, ","):
            pair = split_top_level(entry, "|->")
            if len(pair) != 2:
                return remove_layout_whitespace(value)
            entries.append(
                (canonical_expression(pair[0]), canonical_expression(pair[1])),
            )
        sequence_entries: dict[int, str] = {}
        for key, item in entries:
            if not key.isdecimal() or key.startswith("0"):
                sequence_entries = {}
                break
            sequence_entries[int(key)] = item
        if (
            len(sequence_entries) == len(entries)
            and set(sequence_entries) == set(range(1, len(entries) + 1))
        ):
            return (
                "<<"
                + ",".join(
                    sequence_entries[index]
                    for index in range(1, len(entries) + 1)
                )
                + ">>"
            )
        entries.sort()
        return "[" + ",".join(f"{key}|->{item}" for key, item in entries) + "]"
    if has_outer_delimiters(value, "{", "}"):
        inner = value[1:-1].strip()
        if not inner:
            return "{}"
        items = sorted(canonical_expression(item) for item in split_top_level(inner, ","))
        return "{" + ",".join(items) + "}"
    if has_outer_delimiters(value, "<<", ">>"):
        inner = value[2:-2].strip()
        if not inner:
            return "<<>>"
        items = [canonical_expression(item) for item in split_top_level(inner, ",")]
        return "<<" + ",".join(items) + ">>"
    if has_outer_delimiters(value, "(", ")"):
        return "(" + canonical_expression(value[1:-1]) + ")"
    return remove_layout_whitespace(value)


def rewrite_unquoted_atoms(
    value: str,
    replacements: dict[str, str],
) -> str:
    if not replacements:
        return value

    result: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(value):
        char = value[index]
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            result.append(char)
            index += 1
            continue
        if not (char.isalpha() or char == "_"):
            result.append(char)
            index += 1
            continue

        end = index + 1
        while end < len(value) and (
            value[end].isalnum() or value[end] == "_"
        ):
            end += 1
        token = value[index:end]
        result.append(replacements.get(token, token))
        index = end
    return "".join(result)


def build_symmetry_rewrites(
    groups: tuple[tuple[str, ...], ...],
) -> tuple[dict[str, str], ...]:
    if not groups:
        return ()

    rewrites: list[dict[str, str]] = []
    permutations = [tuple(itertools.permutations(group)) for group in groups]
    for selected in itertools.product(*permutations):
        rewrite: dict[str, str] = {}
        changed = False
        for group, permutation in zip(groups, selected, strict=True):
            for source, target in zip(group, permutation, strict=True):
                rewrite[source] = target
                changed |= source != target
        if changed:
            rewrites.append(rewrite)
    return tuple(rewrites)


def canonical_state(
    value: str,
    symmetry_rewrites: tuple[dict[str, str], ...] = (),
) -> str:
    assignments: list[tuple[str, str]] = []
    current: list[str] = []
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("/\\ "):
            if current:
                assignment = " ".join(current)
                if " = " not in assignment:
                    raise ValueError(f"invalid state assignment: {assignment}")
                name, expression = assignment.split(" = ", 1)
                assignments.append((name, canonical_expression(expression)))
            current = [line[3:]]
        elif current:
            current.append(line)
        else:
            raise ValueError(f"state continuation has no assignment: {raw_line}")
    if current:
        assignment = " ".join(current)
        if " = " not in assignment:
            raise ValueError(f"invalid state assignment: {assignment}")
        name, expression = assignment.split(" = ", 1)
        assignments.append((name, canonical_expression(expression)))
    assignments.sort()
    canonical = "\n".join(
        f"{name}={expression}"
        for name, expression in assignments
    )
    if not symmetry_rewrites:
        return canonical

    result = canonical
    for rewrite in symmetry_rewrites:
        candidate = "\n".join(
            f"{name}={canonical_expression(rewrite_unquoted_atoms(expression, rewrite))}"
            for name, expression in assignments
        )
        result = min(result, candidate)
    return result


def project_state(state: str, variable_names: tuple[str, ...]) -> str:
    assignments = dict(
        line.split("=", 1)
        for line in state.splitlines()
    )
    missing = set(variable_names) - assignments.keys()
    if missing:
        raise ValueError(
            "state is missing identity variables: " + ", ".join(sorted(missing)),
        )
    return "\n".join(
        f"{name}={assignments[name]}"
        for name in sorted(variable_names)
    )


def shortest_levels(
    initial: set[int],
    edges: list[tuple[int, int, object]],
) -> dict[int, int]:
    successors: dict[int, list[int]] = defaultdict(list)
    for source, target, _ in edges:
        successors[source].append(target)
    levels = {state_id: 1 for state_id in initial}
    queue = deque(initial)
    while queue:
        source = queue.popleft()
        for target in successors[source]:
            if target in levels:
                continue
            levels[target] = levels[source] + 1
            queue.append(target)
    return levels


def report_representative_differences(
    tlc_states: dict[int, str],
    tlc_initial: set[int],
    tlc_edges: list[tuple[int, int, str]],
    tlzig_states: dict[int, str],
    tlzig_initial: set[int],
    tlzig_edges: list[tuple[int, int, int]],
    identity_vars: tuple[str, ...],
) -> None:
    tlc_by_identity = {
        project_state(state, identity_vars): (state_id, state)
        for state_id, state in tlc_states.items()
    }
    tlzig_by_identity = {
        project_state(state, identity_vars): (state_id, state)
        for state_id, state in tlzig_states.items()
    }
    if len(tlc_by_identity) != len(tlc_states):
        raise ValueError("TLC contains duplicate projected state identities")
    if len(tlzig_by_identity) != len(tlzig_states):
        raise ValueError("tlzig contains duplicate projected state identities")

    tlc_levels = shortest_levels(tlc_initial, tlc_edges)
    tlzig_levels = shortest_levels(tlzig_initial, tlzig_edges)
    tlc_order: dict[int, list[str]] = defaultdict(list)
    for state_id, state in tlc_states.items():
        tlc_order[tlc_levels[state_id]].append(project_state(state, identity_vars))
    tlzig_order: dict[int, list[str]] = defaultdict(list)
    for state_id, state in tlzig_states.items():
        tlzig_order[tlzig_levels[state_id]].append(project_state(state, identity_vars))
    for level in sorted(tlc_order.keys() | tlzig_order.keys()):
        expected = tlc_order[level]
        actual = tlzig_order[level]
        if expected == actual:
            continue
        first_index = next(
            (
                index
                for index, pair in enumerate(zip(expected, actual))
                if pair[0] != pair[1]
            ),
            min(len(expected), len(actual)),
        )
        print(
            f"projected discovery order first differs at level={level} "
            f"index={first_index} TLC count={len(expected)} "
            f"tlzig count={len(actual)}",
        )
        break
    differences: list[tuple[int, int, str, int, int, str, str]] = []
    for identity in tlc_by_identity.keys() & tlzig_by_identity.keys():
        tlc_id, tlc_state = tlc_by_identity[identity]
        tlzig_id, tlzig_state = tlzig_by_identity[identity]
        if tlc_state == tlzig_state:
            continue
        differences.append(
            (
                tlc_levels.get(tlc_id, sys.maxsize),
                tlzig_levels.get(tlzig_id, sys.maxsize),
                identity,
                tlc_id,
                tlzig_id,
                tlc_state,
                tlzig_state,
            ),
        )

    print(f"concrete representative differences: {len(differences)}")
    if not differences:
        return
    level_pairs = Counter(
        (tlc_level, tlzig_level)
        for tlc_level, tlzig_level, _, _, _, _, _ in differences
    )
    print(f"  level pairs: {sorted(level_pairs.items())}")
    first = min(differences, key=lambda item: (item[0], item[1], item[2]))
    tlc_assignments = dict(line.split("=", 1) for line in first[5].splitlines())
    tlzig_assignments = dict(line.split("=", 1) for line in first[6].splitlines())
    differing_variables = sorted(
        name
        for name in tlc_assignments.keys() | tlzig_assignments.keys()
        if tlc_assignments.get(name) != tlzig_assignments.get(name)
    )
    print(
        f"  first difference: TLC level={first[0]} "
        f"tlzig level={first[1]} TLC id={first[3]} tlzig id={first[4]} "
        f"variables={','.join(differing_variables)}",
    )
    tlc_level_counts: dict[int, int] = defaultdict(int)
    tlc_level_positions: dict[int, int] = {}
    for state_id in tlc_states:
        level = tlc_levels[state_id]
        tlc_level_positions[state_id] = tlc_level_counts[level]
        tlc_level_counts[level] += 1
    tlzig_level_counts: dict[int, int] = defaultdict(int)
    tlzig_level_positions: dict[int, int] = {}
    for state_id in tlzig_states:
        level = tlzig_levels[state_id]
        tlzig_level_positions[state_id] = tlzig_level_counts[level]
        tlzig_level_counts[level] += 1
    tlc_parents = [
        source
        for source, target, _ in tlc_edges
        if target == first[3]
    ]
    tlzig_parents = [
        source
        for source, target, _ in tlzig_edges
        if target == first[4]
    ]
    print(
        "  incoming parent positions: "
        f"TLC={[(parent, tlc_levels[parent], tlc_level_positions[parent]) for parent in tlc_parents]} "
        f"tlzig={[(parent, tlzig_levels[parent], tlzig_level_positions[parent]) for parent in tlzig_parents]}",
    )
    for name in differing_variables:
        tlc_value = tlc_assignments.get(name, "<missing>")
        tlzig_value = tlzig_assignments.get(name, "<missing>")
        print(f"    {name}: TLC={tlc_value[:256]} tlzig={tlzig_value[:256]}")


def canonicalize_state_item(item: tuple[int, str]) -> tuple[int, str]:
    state_id, state = item
    return state_id, canonical_state(state, WORKER_SYMMETRY_REWRITES)


def initialize_canonicalizer(
    symmetry_rewrites: tuple[dict[str, str], ...],
) -> None:
    global WORKER_SYMMETRY_REWRITES
    WORKER_SYMMETRY_REWRITES = symmetry_rewrites


def canonicalize_states(
    raw_states: dict[int, str],
    workers: int,
    label: str,
    symmetry_rewrites: tuple[dict[str, str], ...],
) -> dict[int, str]:
    if workers <= 1 or len(raw_states) < 1000:
        return {
            state_id: canonical_state(state, symmetry_rewrites)
            for state_id, state in raw_states.items()
        }

    result: dict[int, str] = {}
    context = multiprocessing.get_context("spawn")
    with context.Pool(
        processes=workers,
        initializer=initialize_canonicalizer,
        initargs=(symmetry_rewrites,),
    ) as pool:
        canonical = pool.imap_unordered(
            canonicalize_state_item,
            raw_states.items(),
            chunksize=32,
        )
        for count, (state_id, state) in enumerate(canonical, start=1):
            result[state_id] = state
            if count % 50_000 == 0:
                print(
                    f"{label}: canonicalized {count}/{len(raw_states)} states",
                    file=sys.stderr,
                    flush=True,
                )
    return result


def parse_tlzig_states(
    path: Path,
    workers: int,
    symmetry_rewrites: tuple[dict[str, str], ...],
) -> dict[int, str]:
    raw_states: dict[int, str] = {}
    state_id: int | None = None
    state_lines: list[str] = []

    def finish_state() -> None:
        nonlocal state_id, state_lines
        if state_id is None:
            return
        raw_states[state_id] = "\n".join(state_lines)
        state_id = None
        state_lines = []

    with path.open(encoding="utf-8") as state_file:
        for raw_line in state_file:
            line = raw_line.rstrip("\n")
            match = STATE_HEADER_RE.fullmatch(line)
            if match is not None:
                finish_state()
                state_id = int(match.group(1))
                continue
            if not line:
                finish_state()
                continue
            if state_id is None:
                raise ValueError(f"state content has no header: {line}")
            state_lines.append(line)
    finish_state()

    for parsed_id in raw_states:
        if parsed_id < 0:
            raise ValueError(f"invalid tlzig state id: {parsed_id}")
    return canonicalize_states(
        raw_states,
        workers,
        "tlzig",
        symmetry_rewrites,
    )


def parse_tlc_dot(
    path: Path,
    workers: int,
    symmetry_rewrites: tuple[dict[str, str], ...],
) -> tuple[dict[int, str], set[int], list[tuple[int, int, str]]]:
    raw_states: dict[int, str] = {}
    initial: set[int] = set()
    edges: list[tuple[int, int, str]] = []
    with path.open(encoding="utf-8") as dot_file:
        for raw_line in dot_file:
            line = raw_line.rstrip("\n")
            edge_match = EDGE_RE.match(line)
            if edge_match is not None:
                edges.append(
                    (
                        int(edge_match.group(1)),
                        int(edge_match.group(2)),
                        dot_unescape(edge_match.group(3)),
                    ),
                )
                continue
            node_match = NODE_RE.match(line)
            if node_match is None:
                continue
            state_id = int(node_match.group(1))
            state = dot_unescape(node_match.group(2))
            previous = raw_states.setdefault(state_id, state)
            if previous != state:
                raise ValueError(f"TLC node {state_id} has conflicting labels")
            if re.search(r"\bstyle\s*=\s*filled\b", node_match.group(3)):
                initial.add(state_id)
    return (
        canonicalize_states(
            raw_states,
            workers,
            "TLC",
            symmetry_rewrites,
        ),
        initial,
        edges,
    )


def parse_id_set(path: Path) -> set[int]:
    return {
        int(line)
        for raw in path.read_text(encoding="utf-8").splitlines()
        if (line := raw.strip())
    }


def parse_tlzig_edges(path: Path) -> list[tuple[int, int, int]]:
    result: list[tuple[int, int, int]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        source_text, target_text, mask_text = line.split()
        result.append((int(source_text), int(target_text), int(mask_text)))
    return result


def action_name(label: str) -> str:
    return label.split("(", 1)[0]


def parse_fairness(value: str) -> tuple[int, frozenset[str]]:
    bit_text, separator, names_text = value.partition(":")
    if not separator:
        raise argparse.ArgumentTypeError("fairness must be BIT:ACTION[,ACTION]")
    bit = int(bit_text)
    if bit < 0 or bit >= 64:
        raise argparse.ArgumentTypeError("fairness bit must be in 0..63")
    names = frozenset(name for name in names_text.split(",") if name)
    if not names:
        raise argparse.ArgumentTypeError("fairness requires at least one action")
    return bit, names


def parse_fairness_label(value: str) -> tuple[int, str]:
    bit_text, separator, label = value.partition(":")
    if not separator:
        raise argparse.ArgumentTypeError("fairness label must be BIT:LABEL")
    bit = int(bit_text)
    if bit < 0 or bit >= 64:
        raise argparse.ArgumentTypeError("fairness bit must be in 0..63")
    if not label:
        raise argparse.ArgumentTypeError("fairness label cannot be empty")
    return bit, label


def parse_symmetry_atoms(value: str) -> tuple[str, ...]:
    atoms = tuple(atom for atom in value.split(",") if atom)
    if len(atoms) < 2:
        raise argparse.ArgumentTypeError(
            "symmetry group requires at least two comma-separated atoms"
        )
    if len(set(atoms)) != len(atoms):
        raise argparse.ArgumentTypeError("symmetry group contains duplicate atoms")
    for atom in atoms:
        if SYMMETRY_ATOM_RE.fullmatch(atom) is None:
            raise argparse.ArgumentTypeError(
                f"symmetry atom is not an identifier: {atom}"
            )
    return atoms


def parse_identity_vars(value: str) -> tuple[str, ...]:
    names = tuple(name for name in value.split(",") if name)
    if not names:
        raise argparse.ArgumentTypeError("identity variables cannot be empty")
    if len(set(names)) != len(names):
        raise argparse.ArgumentTypeError("identity variables contain duplicates")
    for name in names:
        if SYMMETRY_ATOM_RE.fullmatch(name) is None:
            raise argparse.ArgumentTypeError(
                f"identity variable is not an identifier: {name}",
            )
    return names


def report_difference(label: str, expected: set[object], actual: set[object]) -> bool:
    missing = expected - actual
    extra = actual - expected
    print(
        f"{label}: expected={len(expected)} actual={len(actual)} "
        f"missing={len(missing)} extra={len(extra)}",
    )
    if missing:
        print(f"  missing example: {next(iter(missing))!r}")
    if extra:
        print(f"  extra example: {next(iter(extra))!r}")
    return not missing and not extra


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tlc-dot", type=Path, required=True)
    parser.add_argument("--tlzig-states", type=Path, required=True)
    parser.add_argument("--tlzig-initial", type=Path, required=True)
    parser.add_argument("--tlzig-graph", type=Path, required=True)
    parser.add_argument(
        "--workers",
        type=int,
        default=min(16, os.cpu_count() or 1),
        help="parallel state canonicalization workers (default: up to 16)",
    )
    parser.add_argument(
        "--identity-vars",
        type=parse_identity_vars,
        metavar="VAR[,VAR]",
        help=(
            "compare projected state identities and report differing concrete "
            "representatives, for example variables used by VIEW"
        ),
    )
    parser.add_argument(
        "--symmetry-atoms",
        action="append",
        default=[],
        type=parse_symmetry_atoms,
        metavar="ATOM,ATOM[,ATOM]",
        help=(
            "canonicalize a full permutation symmetry group; repeat for "
            "independent groups"
        ),
    )
    parser.add_argument(
        "--fairness",
        action="append",
        default=[],
        type=parse_fairness,
        metavar="BIT:ACTION[,ACTION]",
        help="map a tlzig fairness-mask bit to TLC leaf action names",
    )
    parser.add_argument(
        "--fairness-label",
        action="append",
        default=[],
        type=parse_fairness_label,
        metavar="BIT:LABEL",
        help=(
            "map a tlzig fairness-mask bit to an exact TLC action label; "
            "repeat the option to union multiple labels for one bit"
        ),
    )
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be greater than zero")
    symmetry_groups = tuple(args.symmetry_atoms)
    symmetry_atoms = [atom for group in symmetry_groups for atom in group]
    if len(set(symmetry_atoms)) != len(symmetry_atoms):
        parser.error("a symmetry atom cannot appear in multiple groups")
    symmetry_rewrites = build_symmetry_rewrites(symmetry_groups)

    tlc_states, tlc_initial_ids, tlc_raw_edges = parse_tlc_dot(
        args.tlc_dot,
        args.workers,
        symmetry_rewrites,
    )
    tlzig_states = parse_tlzig_states(
        args.tlzig_states,
        args.workers,
        symmetry_rewrites,
    )
    tlzig_initial_ids = parse_id_set(args.tlzig_initial)
    tlzig_raw_edges = parse_tlzig_edges(args.tlzig_graph)

    if args.identity_vars is not None:
        report_representative_differences(
            tlc_states,
            tlc_initial_ids,
            tlc_raw_edges,
            tlzig_states,
            tlzig_initial_ids,
            tlzig_raw_edges,
            args.identity_vars,
        )
        tlc_states = {
            state_id: project_state(state, args.identity_vars)
            for state_id, state in tlc_states.items()
        }
        tlzig_states = {
            state_id: project_state(state, args.identity_vars)
            for state_id, state in tlzig_states.items()
        }

    tlc_state_set = set(tlc_states.values())
    tlzig_state_set = set(tlzig_states.values())
    state_identities = {
        state: identity
        for identity, state in enumerate(tlc_state_set | tlzig_state_set)
    }
    tlc_initial = {
        state_identities[tlc_states[state_id]]
        for state_id in tlc_initial_ids
    }
    tlzig_initial = {
        state_identities[tlzig_states[state_id]]
        for state_id in tlzig_initial_ids
    }
    tlc_edges = {
        (
            state_identities[tlc_states[source]],
            state_identities[tlc_states[target]],
        )
        for source, target, _ in tlc_raw_edges
    }
    tlzig_edges = {
        (
            state_identities[tlzig_states[source]],
            state_identities[tlzig_states[target]],
        )
        for source, target, _ in tlzig_raw_edges
    }

    passed = True
    passed &= report_difference("states", tlc_state_set, tlzig_state_set)
    passed &= report_difference("initial states", tlc_initial, tlzig_initial)
    passed &= report_difference("semantic edges", tlc_edges, tlzig_edges)
    if args.identity_vars is not None:
        missing_edges = tlc_edges - tlzig_edges
        extra_edges = tlzig_edges - tlc_edges
        print(
            "edge identity diagnostics: "
            f"missing self={sum(source == target for source, target in missing_edges)} "
            f"extra self={sum(source == target for source, target in extra_edges)}",
        )
    print(
        f"raw edges: TLC={len(tlc_raw_edges)} tlzig={len(tlzig_raw_edges)} "
        f"TLC duplicate witnesses={len(tlc_raw_edges) - len(tlc_edges)}",
    )

    for bit, names in args.fairness:
        tlc_fair = {
            (
                state_identities[tlc_states[source]],
                state_identities[tlc_states[target]],
            )
            for source, target, label in tlc_raw_edges
            if action_name(label) in names
        }
        tlzig_fair = {
            (
                state_identities[tlzig_states[source]],
                state_identities[tlzig_states[target]],
            )
            for source, target, mask in tlzig_raw_edges
            if mask & (1 << bit)
        }
        passed &= report_difference(f"fairness bit {bit}", tlc_fair, tlzig_fair)

    fairness_labels: dict[int, set[str]] = {}
    for bit, label in args.fairness_label:
        fairness_labels.setdefault(bit, set()).add(label)
    for bit, labels in sorted(fairness_labels.items()):
        tlc_fair = {
            (
                state_identities[tlc_states[source]],
                state_identities[tlc_states[target]],
            )
            for source, target, label in tlc_raw_edges
            if label in labels
        }
        tlzig_fair = {
            (
                state_identities[tlzig_states[source]],
                state_identities[tlzig_states[target]],
            )
            for source, target, mask in tlzig_raw_edges
            if mask & (1 << bit)
        }
        passed &= report_difference(
            f"fairness bit {bit} ({', '.join(sorted(labels))})",
            tlc_fair,
            tlzig_fair,
        )

    return 0 if passed else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError) as error:
        print(f"graph comparison failed: {error}", file=sys.stderr)
        sys.exit(2)
