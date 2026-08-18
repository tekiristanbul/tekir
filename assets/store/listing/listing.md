# store / release listing — 0.1 (source of truth)

status: **approved for 0.1** (product owner, 2026-07-29 — mark, icon,
splash, screenshot order, captions direction, short description). the
visual identity is the **temporary 0.1 brand**; issue #24 tracks the final
logo, and replacing it must not require product or architecture changes.

## app

- name: `tekir`
- short description (tr-TR, approved 2026-07-29):
  > İstanbul'daki sokak kedilerini keşfet, son durumlarını gör ve bakımın
  > devam etmesine katkı sağla.
- icon: `assets/app-icon/source/app-icon.svg` — single source of truth;
  all web/pwa exports are generated from it (`uv run
  assets/scripts/generate.py`)
- logo/wordmark: `assets/brand/temporary/source/tekir-wordmark.svg`

## supported release platforms (0.1)

- web / PWA
- ios / App Store (product-owner decision 2026-07-29): bundle id
  `istanbul.tekir` (reverse of tekir.istanbul — must match the apple
  developer app record and the firebase ios app), min ios 15
  (firebase-ios-sdk 12 floor). icon set and native launch screen are
  generated from the canonical sources; App Store screenshots must be
  captured from the real ios build at the device sizes App Store
  Connect requires at submission time — the web captures below are not
  submittable there
- android / Google Play: **0.1 release target — store-ready, publish
  timing is the product owner's** (2026-07-29). package id
  `istanbul.tekir` (same as ios), launcher/adaptive icons and native
  launch screen generated from the canonical sources, play 512 icon at
  `assets/app-icon/android/play-icon-512.png`, required 1024x500
  feature graphic at `assets/store/listing/play-feature-graphic.png`.
  the release artifact is `flutter build appbundle` — play-ready as-is
  once `android/key.properties` points at the upload keystore (see
  `android/key.properties.example`; no code changes needed).

  **published to internal testing 2026-08-17** (`0.4.2`, versionCode 3),
  replaced 2026-08-18 by `0.4.3` versionCode 4.
  console work done in that pass: store listing with the phone captures
  below plus 9:16 tablet variants (play requires exactly 16:9 or 9:16
  with a 1080px minimum side there, which the 780x1688 phone captures do
  not satisfy — they are letterboxed onto a 1080x1920 terracotta canvas,
  never stretched), app content declarations, data safety, content
  rating (12+ / parental guidance, driven by the user-generated-content
  answers), target audience, play app signing, and the firebase android
  app. note that the approved short description above is 97 characters
  and play's limit is 80, so the listing carries a trimmed variant —
  record the exact wording here once it is settled, since this file is
  the source of truth.

  production access still needs a 12-tester, 14-day closed test
  (personal developer account rule)

## locales

- tr-TR only for 0.1

## screenshot order, captions, and intended message

captures go to `assets/store/screenshots/source/`; formatted exports to
`assets/store/screenshots/web/`. captions explain user value, never
implementation. order tells the product story:

| # | screen | source capture | caption (tr-TR) |
|---|--------|----------------|-----------------|
| 1 | map with visible cats | `01-map.png` | İstanbul'un sokak kedileri haritada — yakınındakileri keşfet. |
| 2 | cat detail with recent status | `02-cat-detail.png` | her kedinin son durumu ve geçmişi bir arada. |
| 3 | discover: nearby cats | `03-discover-nearby.png` | çevrendeki kedileri mesafeleriyle birlikte gör. |
| 4 | discover: needs-help cats | `04-discover-needs-help.png` | yardıma ihtiyacı olan kediler anında görünür. |
| 5 | followed cats / notifications | `05-notifications.png` | takip ettiğin kedilerden haberdar ol. |
| 6 | add/update contribution flow | `06-add-update.png` | gördüğün kedinin durumunu birkaç adımda paylaş. |
| 7 | profile and badges | `07-profile-badges.png` | katkıların profilinde ve rozetlerinde birikir. |

`05-alt-notification-optin.png` is an alternate for slot 5 (the follow
notification opt-in sheet) — kept for comparison, not part of the
approved order unless the product owner swaps it in.

captures are 390x844 css @2x (780x1688 png), release web build, seeded
demo data (`backend/cmd/seed`), demo account `Deniz`, fake phone numbers
only. no personal data, tokens, or debug ui.

## approval checklist (before any submission)

- [x] temporary mark approved (product owner, 2026-07-29)
- [x] app icon approved (product owner, 2026-07-29)
- [x] splash approved (product owner, 2026-07-29)
- [x] screenshot selection + order approved (product owner, 2026-07-29)
- [x] short description approved (product owner, 2026-07-29)
- [x] captured screenshots + captions reviewed on the real captures
      (product owner, 2026-07-29 — the web set in
      `screenshots/source/`; review again if any capture is replaced)
- [ ] no secrets/personal data in any capture (web set verified at
      capture time, 2026-07-29; re-verify once the ios/android
      real-build captures complete the final set)
- [ ] ios screenshot set captured from the real ios build at the sizes
      App Store Connect requires (verify against current official docs
      at submission — do not trust sizes written down anywhere in this
      repo)
- [ ] platform dimension requirements re-verified against current official
      store documentation
