# implementation contract

## goal

state, in one place, how [[prototype]] (the hi-fi clickable prototype under `prototype/`) and the product docs (`docs/product/*.md`) each govern the implemented app — added after the flutter cat-detail slice (issue #21) drifted from the approved prototype into generic material defaults, and a marker tap skipped the prototype's preview-sheet step straight to the detail screen. that drift is what this document exists to prevent going forward.

## decisions

- `prototype/` (`index.html`, `styles.css`, `app.js`, `design-system.html`) is the visual-hierarchy and interaction baseline for every mobile surface that has actually been implemented — photo hierarchy, sheet/screen transitions, spacing, color, type, and structures like the update timeline. when an implemented screen's design tokens or interaction model come from anywhere else, that's a bug against this contract, not a valid alternative.
- product docs (`docs/product/*.md`, `docs/architecture/*.md`) are the behavior and data contract — what data exists, what a user can do, what's in scope for a given issue. they do not govern visual hierarchy or interaction sequencing; the prototype does.
- an action that appears in the prototype but is out of scope for the issue being implemented (e.g. follow, submitting an update, needs-help creation/resolution, photo carousel, bottom navigation, discover/account) is not shown in the implementation at all — not disabled, not faked, not stubbed. it simply isn't there until its own issue implements it.
- a deliberate deviation from the prototype (an implemented screen intentionally not matching it) requires product-owner approval first, and must be recorded — in the PR that introduces it and, if it's lasting, in the relevant product/architecture doc — not silently merged.
- a new screen is built by matching the prototype's structure and tokens, not by reinterpreting the product docs' behavior spec from scratch with generic material/cupertino defaults. "there's no prototype screen for this yet" is a reason to ask, not a reason to invent a visual direction.
- `docs/design/screens/cat-profile.html` (imported by issue #100) is the approved 0.2 visual and copy baseline for the cat-profile surface, its media view, and its update sheet. where it conflicts with `prototype/`'s cat-detail screens — most notably the help-category picker (`HELP_REASONS` in `prototype/data.js`) — the imported design supersedes the prototype; the prototype remains the baseline for every other surface. behavior and data rules still come from the product docs (`docs/product/alerts.md` for the simplified help contract), not from this design file. its loading/empty/error states are governed by the application-state contract adoption tracked in issue #98 (`docs/design/screens/app-states.html`).
- `docs/design/app-states.md` with `docs/design/screens/app-states.html` (imported by issue #98) is the approved contract for loading, empty, error, offline, permission, and launch states on every surface — copy, timing, and visual rules are binding there. two recorded consequences: issue #85's full-terracotta splash composition is deliberately superseded by the 12b lockup (an app-state illustration only — issue #24's logo process and its exclusions are unaffected), and the prototype's ad-hoc waiting/empty treatments no longer govern these states.

## authoritative vs historical (issue #121 residue inventory)

`docs/design/` mixes binding references with superseded drafts and
past PRs' evidence — easy to mix up by directory alone, so listed
explicitly here:

- binding: `prototype/` (except cat-profile, per the decision above),
  `docs/design/screens/cat-profile.html`, `docs/design/screens/app-states.html`,
  `docs/design/app-states.md`, this file.
- historical, superseded — kept for record only, never a source of
  truth for an implemented screen: `docs/design/wireframes.md`/
  `wireframes.html` (low-fi, predates the prototype) and
  `docs/design/visual-direction.md` (an earlier ink/paper/amber
  palette, superseded by the prototype's kiremit direction). Both are
  marked with a banner pointing back here.
- evidence, not spec: `docs/design/screenshots/` holds past PRs'
  before/after captures — proof a change shipped, never itself a
  reference to build a new screen against. Not to be confused with
  `docs/design/screens/`, the actual reference markup.

## open questions

None open for this document's own scope. `visual-direction.md`'s
reconciliation (previously listed here) is resolved above: superseded
in practice, retained as historical record rather than retired.
