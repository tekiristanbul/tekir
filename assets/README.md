# release assets (temporary 0.1 identity — issue #85)

everything in this tree is the **temporary 0.1 brand** (approved by the
product owner for 0.1 only, 2026-07-29): a typographic `tekir` wordmark
and a wordmark-derived `t` lettermark, set in the app's own display font
(Fraunces, weight 600) on the approved product palette. **issue #24
remains the final original-logo task. final-logo design is now developed
internally through the maintainer's claude/design workflow rather than as
an open-ended external design task. agents must not independently redesign,
replace, or reinterpret the logo as part of unrelated work.** once an
approved final asset exists, replacing this temporary brand must not require
product or architecture changes, and it doesn't: nothing outside this tree
hardcodes the artwork except the inline copy in `app/web/index.html` (marked
with a comment pointing back here) and the splash lockup in
`app/lib/core/splash/splash_gate.dart`, both of which swap with the regenerated
sources.

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
originally ported from the retired prototype's `styles.css`): terracotta
`#A44732`, ink `#2A1F1B`, white.

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

0.1 release targets are **web/PWA and ios** (product-owner decision
2026-07-29). the generator fills the ios Runner icon set
(`app/ios/Runner/Assets.xcassets/AppIcon.appiconset`, sizes read from
its `Contents.json`, opaque as the store requires) and the native
launch image (the splash tile at 84pt over a terracotta
`LaunchScreen.storyboard` background) from the same canonical sources —
no hand-maintained ios artwork. bundle id: `istanbul.tekir`.

ios steps this repository cannot do (need a mac and the consoles):
xcode signing + first `pod install`/build, APNs key + firebase ios app
registration (`GoogleService-Info.plist`), TestFlight, and capturing
App Store screenshots from the real ios build at the sizes App Store
Connect requires — verify those against the **current** official
documentation at submission; never trust sizes written down here.

android is a **0.1 release target** (product-owner decision
2026-07-29; publish timing is the product owner's): the generator
fills the legacy launcher mipmaps, the adaptive-icon foreground
(lettermark on transparent over the `#A44732` background color
resource, also reused as the android 13 monochrome/themed layer), the
native launch `splash_mark` drawables, the play 512 icon, and the
1024x500 feature graphic. package id `istanbul.tekir`. the store
artifact is `flutter build appbundle`, play-ready as-is once
`android/key.properties` points at the upload keystore
(`android/key.properties.example`). still console-side: play listing
+ data-safety form, play app signing, firebase android app
registration, real-build screenshots at sizes verified against
current official documentation.

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
