"""Checks the repository's markdown for links that no longer resolve.

Two deterministic checks, both of which used to be done by hand:

1. every relative link and image target in a tracked markdown file exists,
   and every heading anchor it points at exists in the target file.
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
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"`[^`]*`")
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*([^()\s]*(?:\([^()]*\)[^()\s]*)*)")
REFERENCE_LINK = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(\S+)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"<[^>]*\b(?:name|id)=[\"']([^\"']+)[\"']")
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


def strip_code(lines: list[str], spans: bool = True) -> list[str]:
    """Blanks fenced blocks so code samples are not read as markdown.

    Inline code spans are blanked too when scanning for links, but kept when
    slugging headings: github renders `code` in a heading as part of the
    anchor text.
    """
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
        stripped.append(CODE_SPAN.sub("", line) if spans else line)
    return stripped


def slug(text: str) -> str:
    """Reproduces github's heading anchor slug."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("`", "").replace("*", "")
    text = re.sub(r"<[^>]+>", "", text)
    kept = [
        c
        for c in text.lower().strip()
        if c in " -_" or c.isalnum() or unicodedata.category(c) == "Mn"
    ]
    return "".join(kept).replace(" ", "-")


def anchors(path: Path) -> set[str]:
    names: set[str] = set()
    seen: dict[str, int] = {}
    lines = (REPO / path).read_text(encoding="utf-8").splitlines()
    for line in strip_code(lines, spans=False):
        heading = HEADING.match(line)
        if heading:
            base = slug(heading.group(2))
            if not base:
                continue
            count = seen.get(base, 0)
            seen[base] = count + 1
            names.add(base if count == 0 else f"{base}-{count}")
        names.update(name.lower() for name in HTML_ANCHOR.findall(line))
    return names


def targets(line: str):
    for match in INLINE_LINK.finditer(line):
        yield match.group(1)
    reference = REFERENCE_LINK.match(line)
    if reference:
        yield reference.group(1)


def check_links(files: list[Path]) -> list[str]:
    anchor_cache: dict[Path, set[str]] = {}
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

                location, _, fragment = target.partition("#")
                if location:
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
                        continue
                    linked = resolved.relative_to(REPO)
                else:
                    linked = path

                if not fragment or linked.suffix != ".md":
                    continue
                if linked not in anchor_cache:
                    anchor_cache[linked] = anchors(linked)
                if fragment.lower() not in anchor_cache[linked]:
                    problems.append(
                        f"{path}:{number}: '{target}' points at a heading "
                        f"that does not exist in {linked}"
                    )

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
