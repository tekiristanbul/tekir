"""Checks the repository's markdown for links that no longer resolve.

Two deterministic checks, both of which used to be done by hand:

1. every relative link and image target in a tracked markdown file exists.
   Only the path is checked; a `#heading` fragment is ignored.
2. `docs/adr/` and its index in `docs/adr/README.md` list exactly the same
   records.

External links are never fetched: this check is offline, deterministic, and
cheap enough to run on every push. Run it from the repository root:

    python3 scripts/check-docs.py
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"`[^`]*`")
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*([^()\s]*(?:\([^()]*\)[^()\s]*)*)")
REFERENCE_LINK = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(\S+)")
SCHEME = re.compile(r"^[a-z][a-z0-9+.\-]*:", re.IGNORECASE)
ADR_RECORD = re.compile(r"^\d{4}-.+\.md$")
ADR_INDEX_ROW = re.compile(r"^\|\s*\[\d{4}\]\((\d{4}-[^)]+\.md)\)")


def tracked_markdown() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md"],
        cwd=REPO,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return sorted(Path(name) for name in out.split("\0") if name)


def strip_code(lines: list[str]) -> list[str]:
    """Blanks fenced blocks and inline code so samples are not read as links."""
    stripped: list[str] = []
    fence: str | None = None
    for line in lines:
        marker = FENCE.match(line)
        if fence is None and marker:
            fence = marker.group(1)[0] * 3
            stripped.append("")
            continue
        if fence is not None:
            if marker and marker.group(1).startswith(fence):
                fence = None
            stripped.append("")
            continue
        stripped.append(CODE_SPAN.sub("", line))
    return stripped


def targets(line: str):
    for match in INLINE_LINK.finditer(line):
        yield match.group(1)
    reference = REFERENCE_LINK.match(line)
    if reference:
        yield reference.group(1)


def check_links(files: list[Path]) -> list[str]:
    problems: list[str] = []

    for path in files:
        lines = (REPO / path).read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(strip_code(lines), start=1):
            for raw in targets(line):
                target = raw.strip()
                if target.startswith("<") and target.endswith(">"):
                    target = target[1:-1]
                if not target or SCHEME.match(target) or target.startswith("//"):
                    continue

                location = target.partition("#")[0]
                if not location:
                    continue
                if location.startswith("/"):
                    problems.append(
                        f"{path}:{number}: '{target}' is an absolute path; "
                        "use a path relative to this file"
                    )
                    continue

                resolved = ((REPO / path).parent / location).resolve()
                if not resolved.is_relative_to(REPO):
                    problems.append(
                        f"{path}:{number}: '{target}' points outside the repository"
                    )
                    continue
                if not resolved.exists():
                    problems.append(f"{path}:{number}: '{target}' does not exist")

    return problems


def check_adr_index() -> list[str]:
    directory = REPO / "docs" / "adr"
    index = directory / "README.md"
    if not index.exists():
        return ["docs/adr/README.md: does not exist"]

    records = {
        entry.name
        for entry in directory.iterdir()
        if ADR_RECORD.match(entry.name) and entry.name != "0000-template.md"
    }
    rows = index.read_text(encoding="utf-8").splitlines()
    listed = {
        match.group(1)
        for match in (ADR_INDEX_ROW.match(row) for row in rows)
        if match
    }

    problems = [
        f"docs/adr/README.md: {name} is not listed in the index"
        for name in sorted(records - listed)
    ]
    problems += [
        f"docs/adr/README.md: the index lists {name}, which is not a "
        "record in docs/adr/"
        for name in sorted(listed - records)
    ]
    return problems


def main() -> int:
    files = tracked_markdown()
    problems = check_links(files) + check_adr_index()

    for problem in problems:
        print(problem)

    if problems:
        print(
            f"\ndocs check failed: {len(problems)} problem(s) "
            f"in {len(files)} markdown files"
        )
        return 1

    print(f"docs check passed: {len(files)} markdown files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
