# wireframes

> **historical — superseded.** These are low-fi structural wireframes that
> predate the hi-fi prototype (`prototype/`), which has since superseded
> them as the visual/interaction baseline. Kept for record only — not a
> source of truth for any implemented screen. See
> `docs/design/implementation-contract.md`'s "authoritative vs historical"
> section (issue #121).

## goal

low-fidelity wireframes for the 9 mvp screens, produced from the information architecture and user-flow pass that preceded `docs/architecture/`.

## decisions

- `wireframes.html` is a single self-contained page — open it directly in a browser, no build step or server needed.
- covers, in flow order: map, cat detail, add update, add cat (location step), add cat (details step), discover, notifications, account, login.
- each screen shows a low-fi phone-frame mockup (grayscale, dashed borders for optional elements, crossed-box placeholders for photos/media) plus a spec panel: user goal, primary action, secondary action, required info, required components — and an open-question note where one applies.
- visual style is intentionally placeholder-grade — colors/typography are wireframe conventions, not the product's final visual identity.

## open questions

- final visual identity (color, typography, real component styling) is not started — these are structural wireframes only.
- a `claude.ai/design` upload of the same 9 screens was attempted and abandoned: rendering never worked reliably there, and `/design-sync` (the tool meant for this) applies to compiled component-library repos, not pre-code wireframes. this file is the reference copy.

## out of scope

- interactive prototyping beyond screen-to-screen navigation (the page has simple tab switching between screens, not full click-through flows).
- a figma file — not produced yet.
