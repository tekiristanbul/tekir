# contributing

## commit messages

- language: english, always — regardless of the language used elsewhere (issues, discussion, code comments).
- format: `<type>: description`, imperative mood, lowercase after the colon.
- allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `style`, `perf`, `build`, `ci`, `revert`.
- subject line: 50 characters max.
- if a body is needed, leave a blank line after the subject, then wrap body lines at 72 characters.
- trailers (`Co-Authored-By:`, `Signed-off-by:`) are exempt from the wrap limit.

these are enforced by a `commit-msg` hook in `.githooks/`. enable it once per clone:

```sh
git config core.hooksPath .githooks
```

(git hooks aren't enabled by cloning alone — this has to be run locally once.)
