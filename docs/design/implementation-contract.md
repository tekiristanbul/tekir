# implementation contract

## goal

state, in one place, how the shipped implementation and the product docs (`docs/product/*.md`) each govern the app — added after the flutter cat-detail slice (issue #21) drifted from the approved prototype into generic material defaults, and a marker tap skipped the prototype's preview-sheet step straight to the detail screen. that drift is what this document exists to prevent going forward.

`prototype/` (the original hi-fi clickable prototype) served as the visual-hierarchy and interaction baseline while the app was first being built. it has been retired (issue #192): every mvp surface it covered has since shipped, and the shipped app is now that baseline. `prototype/` is removed from the repository; do not point implementation work at it.

## decisions

- the shipped implementation (`app/`) is the visual-hierarchy and interaction baseline for every mobile surface that has actually been built — photo hierarchy, sheet/screen transitions, spacing, color, type, and structures like the update timeline. when a new screen's design tokens or interaction model diverge from the existing app without a recorded reason, that's a bug against this contract, not a valid alternative.
- product docs (`docs/product/*.md`, `docs/architecture/*.md`) are the behavior and data contract — what data exists, what a user can do, what's in scope for a given issue. they do not govern visual hierarchy or interaction sequencing; the shipped implementation and this document do.
- an action that has no existing implementation and is out of scope for the issue being implemented (e.g. an unbuilt flow, a deferred feature) is not shown in the implementation at all — not disabled, not faked, not stubbed. it simply isn't there until its own issue implements it.
- a deliberate deviation from the existing shipped pattern for a surface requires product-owner approval first, and must be recorded — in the PR that introduces it and, if it's lasting, in the relevant product/architecture doc — not silently merged.
- a new screen is built by matching the existing app's structure and tokens (`app/lib/core/theme/`), not by reinterpreting the product docs' behavior spec from scratch with generic material/cupertino defaults. "there's no existing screen like this yet" is a reason to ask, not a reason to invent a visual direction.
- `docs/design/screens/cat-profile.html` (imported by issue #100) is the approved 0.2 visual and copy baseline for the cat-profile surface, its media view, and its update sheet. behavior and data rules still come from the product docs (`docs/product/alerts.md` for the simplified help contract), not from this design file. its loading/empty/error states are governed by the application-state contract adoption tracked in issue #98 (`docs/design/screens/app-states.html`).
- `docs/design/app-states.md` with `docs/design/screens/app-states.html` (imported by issue #98) is the approved contract for loading, empty, error, offline, permission, and launch states on every surface — copy, timing, and visual rules are binding there.

## authoritative vs historical

`docs/design/` mixes binding references with superseded drafts and
past PRs' evidence — easy to mix up by directory alone, so listed
explicitly here:

- binding: the shipped implementation (`app/`), `docs/design/screens/cat-profile.html`,
  `docs/design/screens/app-states.html`, `docs/design/app-states.md`, this file.
- historical, superseded — kept for record only, never a source of
  truth for an implemented screen: `docs/design/wireframes.md`/
  `wireframes.html` (low-fi, predates the original prototype) and
  `docs/design/visual-direction.md` (an earlier ink/paper/amber
  palette, superseded by the prototype's kiremit direction, which the
  shipped app's tokens now carry forward). `docs/design/issue-121-visual-parity-audit.md`
  (a point-in-time source diff against the now-removed prototype).
  All are marked with a banner pointing back here.
- evidence, not spec: `docs/design/screenshots/` holds past PRs'
  before/after captures — proof a change shipped, never itself a
  reference to build a new screen against. Not to be confused with
  `docs/design/screens/`, the actual reference markup.

## open questions

None.
