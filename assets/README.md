# release assets (temporary 0.1 identity — issue #85)

everything in this tree is the **temporary 0.1 brand** (approved by the
product owner for 0.1 only, 2026-07-29): a typographic `tekir` wordmark
and a wordmark-derived `t` lettermark, set in the app's own display font
(Fraunces, weight 600) on the approved product palette. **issue #24
remains the final original-logo task** — replacing this brand must not
require product or architecture changes, and it doesn't: nothing outside
this tree hardcodes the artwork except the inline copy in
`app/web/index.html` (marked with a comment pointing back here) and the
splash lockup in `app/lib/core/splash/splash_gate.dart`, both of which
swap with the regenerated sources.

## structure

```text
assets/
  scripts/generate.py       single source of truth — regenerates everything
  brand/temporary/
    source/                 canonical editable SVGs (outlined paths)
    exports/                transparent wordmark PNGs, github/firebase icons
  app-icon/
    source/app-icon.svg     1024x1024 icon master
    web/                    favicon + PWA icon exports
  splash/
    source/                 splash mark + full-frame reference SVGs
    exports/                1080x2340 splash reference PNG
  store/
    listing/listing.md      store/listing source of truth
    screenshots/source/     original uncropped captures (committed as taken)
    screenshots/web/        platform-formatted exports
```

## generation

the mark is pure typography, so the generator script *is* the editable
master: it shapes the text with harfbuzz against the fonts already bundled
with the app (`app/assets/fonts/`), pinned to the exact instance the app
renders (Fraunces wght 600, all other axes default), and emits every SVG
and PNG in this tree plus the live targets. rerun after any change:

```bash
uv run assets/scripts/generate.py
```

it also overwrites the wired-in copies:

- `app/web/favicon.png`, `app/web/icons/Icon-*.png` (flutter web/PWA)
- `website/assets/favicon.png`

and prints the pixel metrics used by the hand-inlined white SVGs in
`app/web/index.html` (pre-flutter launch screen). if the mark changes,
re-inline those paths from `brand/temporary/source/*.svg` and update the
printed dimensions.

colors come from the approved palette (`app/lib/core/theme/app_theme.dart`,
ported from `prototype/styles.css`): terracotta `#A44732`, ink `#2A1F1B`,
white.

## usage notes

- **full-color** wordmark (terracotta) on light backgrounds; **white** on
  terracotta/photography; **ink** where a neutral dark mono mark is needed.
- keep clear space of at least the height of the `t` crossbar around the
  wordmark; don't set it smaller than ~16 px tall.
- the app icon is full-bleed terracotta with the lettermark at 45% of the
  canvas — inside the maskable safe zone (circle, r = 40%), so the same
  master serves plain and maskable exports.
- github organization avatar: `brand/temporary/exports/github-avatar.png`
  (500x500). firebase console icon:
  `brand/temporary/exports/firebase-icon.png` (512x512).

## splash

the launch splash is implemented in `app/lib/core/splash/splash_gate.dart`
(flutter, prototype composition, dismisses when session restore settles,
capped at 2 s) with a matching static pre-engine copy inlined in
`app/web/index.html` that fades out on `flutter-first-frame`, so web
startup is terracotta from the first byte with no white flash.
`splash/source/splash-screen.svg` is the composition reference.

## platforms and stores

only **web** is a release-supported 0.1 target (see DEVELOPMENT.md); the
flutter android/ios targets don't exist in this repository yet. per issue
\#85, no Play/App Store icon or screenshot sets are pre-generated for
unsupported platforms. when a mobile target is added:

1. add the platform export sizes to `scripts/generate.py` from the icon
   master (android adaptive icons need a separate foreground layer —
   lettermark on transparent — plus `#A44732` background; ios icons must
   be opaque, which the full-bleed master already is),
2. verify dimensions against the **current** official store documentation
   at that moment (don't trust sizes written down here),
3. capture the store screenshot sets per `store/listing/listing.md`.

## screenshots

capture from the real running app against seeded demo data — never the
prototype, never production user data. checklist per capture:

- no phone numbers, tokens, personal data, internal urls, debug banners,
  or precise private locations visible
- deterministic seed data (`backend` seed tooling), so captures are
  reproducible
- store originals uncropped in `store/screenshots/source/`, formatted
  exports per platform in `store/screenshots/web/` (and siblings later)

the shot list, order, and intended message live in
`store/listing/listing.md` and need product-owner approval before any
store/distribution submission.
