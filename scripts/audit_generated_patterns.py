#!/usr/bin/env python3
import argparse
import pathlib
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Pattern:
    name: str
    regex: re.Pattern[str]
    reason: str


PATTERNS = [
    Pattern(
        "nested_runtime_call",
        re.compile(r"runtime\.[A-Za-z0-9_]+\([^;\n]*runtime\."),
        "helper chains that should often become one native primitive",
    ),
    Pattern(
        "except_update",
        re.compile(r"runtime\.except_update\("),
        "generic EXCEPT reconstruction in action assignments",
    ),
    Pattern(
        "variable_except_update",
        re.compile(r"runtime\.variable_except_update\("),
        "state-variable EXCEPT still using an updater callback",
    ),
    Pattern(
        "fused_variable_except_set_insert",
        re.compile(r"runtime\.variable_except_update_set_insert\("),
        "syntax-proven state-variable set insertions lowered to one reconstruction",
    ),
    Pattern(
        "fused_variable_except_set_remove",
        re.compile(r"runtime\.variable_except_update_set_remove\("),
        "syntax-proven state-variable set removals lowered to one reconstruction",
    ),
    Pattern(
        "primed_except_update_callback",
        re.compile(r"runtime\.primed_variable_except_update_path_equal_bool\("),
        "primed EXCEPT comparisons that still invoke an updater callback",
    ),
    Pattern(
        "direct_primed_except_set_insert",
        re.compile(
            r"runtime\.primed_variable_except_update_path_set_insert_equal_bool\("
        ),
        "syntax-proven primed set insertions compared without materialization",
    ),
    Pattern(
        "direct_primed_except_set_remove",
        re.compile(
            r"runtime\.primed_variable_except_update_path_set_remove_equal_bool\("
        ),
        "syntax-proven primed set removals compared without materialization",
    ),
    Pattern(
        "variable_path",
        re.compile(r"runtime\.variable_path\("),
        "generic state path lookup instead of typed/indexed access",
    ),
    Pattern(
        "primed_variable_full_compare",
        re.compile(
            r"runtime\.(?:equal|not_equal)_bool\(context\.eval_pool,\s*"
            r"try runtime\.primed_variable\(context,\s*\d+\)\s*,",
        ),
        "whole-root next-state equality checks",
    ),
    Pattern(
        "primed_variable_path_compare",
        re.compile(
            r"runtime\.(?:equal|not_equal)_bool\([^;\n]*"
            r"runtime\.call\(context,\s*try runtime\.primed_variable",
        ),
        "indexed next-state paths evaluated through a generic function call",
    ),
    Pattern(
        "unchanged_variable",
        re.compile(r"runtime\.unchanged_variable\("),
        "one runtime call per unchanged root instead of grouped/root mask checks",
    ),
    Pattern(
        "unchanged_expression",
        re.compile(r"runtime\.unchanged_expression\("),
        "generic unchanged expression evaluation",
    ),
    Pattern(
        "field_sequence_head",
        re.compile(r"runtime\.field\([^;\n]*runtime\.sequence_head"),
        "sequence-head record-field guard that can be a direct helper",
    ),
    Pattern(
        "map_set",
        re.compile(r"runtime\.map_set\("),
        "generic mapped-set construction in hot action expressions",
    ),
    Pattern(
        "function_range",
        re.compile(r"runtime\.function_range\("),
        "generic range materialization",
    ),
    Pattern(
        "permutations_union_chain",
        re.compile(r"runtime\.set_union\([^;\n]*runtime\.permutations"),
        "nested permutation unions should use runtime.permutations_union",
    ),
]


def iter_files(paths: list[str]) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for raw in paths:
        path = pathlib.Path(raw)
        if path.is_dir():
            files.extend(sorted(path.glob("*.zig")))
        elif path.is_file():
            files.append(path)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit generated Zig for helper-heavy patterns.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        default=["generated_models"],
        help="generated .zig files or directories to scan",
    )
    parser.add_argument(
        "--examples",
        type=int,
        default=3,
        help="line examples to print per pattern",
    )
    args = parser.parse_args()

    files = iter_files(args.paths)
    totals = {pattern.name: 0 for pattern in PATTERNS}
    examples: dict[str, list[tuple[pathlib.Path, int, str]]] = {
        pattern.name: [] for pattern in PATTERNS
    }

    for path in files:
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), 1):
            for pattern in PATTERNS:
                count = len(pattern.regex.findall(line))
                if count == 0:
                    continue
                totals[pattern.name] += count
                if len(examples[pattern.name]) < args.examples:
                    examples[pattern.name].append(
                        (path, line_number, line.strip()),
                    )

    print(f"scanned_files={len(files)}")
    for pattern in PATTERNS:
        print(f"{pattern.name}: {totals[pattern.name]} -- {pattern.reason}")
        for path, line_number, line in examples[pattern.name]:
            print(f"  {path}:{line_number}: {line[:220]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
