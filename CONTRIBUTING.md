# contributing

## commit messages

- language: english, always — regardless of the language used elsewhere (issues, discussion, code comments).
- format: `<type>: description`, imperative mood, lowercase after the colon.
- allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `style`, `perf`, `build`, `ci`, `revert`.
- subject line: 50 characters max.
- if a body is needed, leave a blank line after the subject, then wrap body lines at 72 characters.
- trailers (`Co-Authored-By:`, `Signed-off-by:`) are exempt from the wrap limit.

## authorship

- ai tools (including claude code, used to draft parts of this project) must never appear as a commit author, committer, or `Co-Authored-By:` trailer. the human contributor who made the commit is solely responsible for its content, regardless of what tooling helped produce it.

these are enforced by a `commit-msg` hook in `.githooks/`. a `pre-commit` hook there also blocks committing a real google maps api key into `app/web/index.html` (see `app/scripts/run_web.sh`). enable both once per clone:

```sh
git config core.hooksPath .githooks
```

(git hooks aren't enabled by cloning alone — this has to be run locally once.)

## where things live

- product decisions → `docs/product/` (one file per topic).
- architecture decisions → `docs/architecture/` (api, db, flutter, backend).
- design artifacts (wireframes, mockups, diagrams) → `docs/design/`, each asset paired with a short `.md` covering goal, decisions, open questions, and out of scope — same structure as `docs/product/`.

nothing that's meant to persist stays only in a chat artifact, a scratch file, or an external tool (figma, claude.ai/design) without a copy landing in the matching `docs/` folder above, committed like everything else.
