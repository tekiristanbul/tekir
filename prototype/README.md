# cats istanbul — hi-fi prototype

Built for issue #5: a locally browsable, visually complete pass over the screens and flows in
`docs/design/wireframes.html`. Not Figma — no build step or framework, opens directly as `index.html`
or runs from a simple static server.

Note: the in-app product copy (button labels, cat statuses, screen text) is intentionally in Turkish —
Turkish street-cat helpers are the primary audience for the real product. This README, the design
system's own labels, and everything else in the repo (code, comments, commits) are in English.

## running it

```
cd prototype
python3 -m http.server 8000
```

then open `http://localhost:8000`. double-clicking `index.html` to open it via `file://` also works;
the map needs an internet connection — without one it falls back to a static patterned background,
with the cat markers still visible.

## files

- `index.html` — app shell, 9 screens
- `styles.css` — design tokens (color, typography, spacing, radius, elevation) + reusable component classes
- `icons.js` — shared svg icon set, used by both the app and design-system.html
- `app.js` — screen rendering, state, navigation, leaflet map integration
- `design-system.html` — screen-independent component/token catalog, uses the same `styles.css`

## cat photos

All real, CC-licensed street cat photos sourced from wikimedia commons:

| used for | file | photographer | license |
|---|---|---|---|
| Portakal | [Cat near Kabataş in Istanbul](https://commons.wikimedia.org/wiki/File:Cat_near_Kabata%C5%9F_in_Istanbul,_20260605_1734_1298.jpg) | Jakub Hałun | CC BY 4.0 |
| Zeytin | [Cats, Kadikoey, Istanbul](https://commons.wikimedia.org/wiki/File:Cats,_Kadikoey,_Istanbul_(P1100168).jpg) | Matti Blume | CC BY-SA |
| Sultan | [Istanbul - cat of Sultanahmet](https://commons.wikimedia.org/wiki/File:Istanbul_-_cat_of_Sultanahmet.jpg) | Jorge Franganillo | CC BY 4.0 |
| (unnamed, white-ginger) | [Old Istanbul Cat](https://commons.wikimedia.org/wiki/File:Old_Istanbul_Cat.jpg) | Amak-i Hayal | CC BY-SA 4.0 |
| Yavru | [Cat, Istanbul (P1180136)](https://commons.wikimedia.org/wiki/File:Cat,_Istanbul_(P1180136).jpg) | Matti Blume | CC BY-SA |
| Kaplan | [Turkey (Istanbul) Street cat](https://commons.wikimedia.org/wiki/File:Turkey_(Istanbul)_Street_cat_(21956691179).jpg) | Flickr / f_snarfel | CC BY 2.0 |

if an image fails to load (`onerror`), every `<img>` falls back to a paw-icon placeholder in the brand
color — no empty gray placeholders.

## map

leaflet + openstreetmap, via cdn (`unpkg.com/leaflet`). centered on kadıköy/moda, street-level zoom.
if the leaflet cdn fails to load, or tile requests fail, the app automatically falls back to rendering
the same cat markers as absolutely-positioned elements over a static grid background — the map never
goes empty. this fallback is exercised by both the synchronous init-failure path and leaflet's async
`tileerror` event, through one shared `activateMapFallback()` function.

## scoped-out / adapted decisions

- per `docs/product/trust.md`: a text-only status update, and following a cat, both work without
  logging in; only adding a photo/video or adding a new cat requires login + phone verification.
- per `docs/product/alerts.md`: creating a "needs help" alert always requires login, even without a
  photo — alerts notify followers, so they sit behind a higher trust bar.
- the wireframe's "continue without media" action was dropped — per the rule above, a text-only update
  never needed login to begin with, so that shortcut no longer applies. replaced with a generic "cancel".
- the first submit attempt on a status update is deliberately simulated to fail once, to demonstrate the
  error + "retry" state; subsequent attempts succeed normally.
- the "add cat: location" screen starts centered near an existing cat (Portakal) on purpose, so the
  "is this cat already registered here?" duplicate-check modal is reachable on the very first try.
