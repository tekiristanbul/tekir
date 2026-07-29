# store / release listing — 0.1 (source of truth)

status: **approved for 0.1** (product owner, 2026-07-29 — mark, icon,
splash, screenshot order, captions direction, short description). the
visual identity is the **temporary 0.1 brand**; issue #24 tracks the final
logo, and replacing it must not require product or architecture changes.

## app

- name: `tekir`
- short description (tr-TR, approved 2026-07-29):
  > istanbul'daki sokak kedilerini keşfet, son durumlarını gör ve bakımın
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
- android: store assets may be prepared from the same sources, but
  native release stays out of scope for 0.1

## locales

- tr-TR only for 0.1

## screenshot order, captions, and intended message

captures go to `assets/store/screenshots/source/`; formatted exports to
`assets/store/screenshots/web/`. captions explain user value, never
implementation. order tells the product story:

| # | screen | source capture | caption (tr-TR) |
|---|--------|----------------|-----------------|
| 1 | map with visible cats | `01-map.png` | istanbul'un sokak kedileri haritada — yakınındakileri keşfet. |
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
- [ ] final captured screenshots + captions reviewed on the real captures
- [ ] no secrets/personal data in any capture (re-verify on final set)
- [ ] ios screenshot set captured from the real ios build at the sizes
      App Store Connect requires (verify against current official docs
      at submission — do not trust sizes written down anywhere in this
      repo)
- [ ] platform dimension requirements re-verified against current official
      store documentation
