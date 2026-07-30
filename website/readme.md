# website

the public landing page for tekir: `index.html` + `styles.css`, no build step, no framework, no dependency on the api or the flutter app. the primary action is `Open the app` → <https://app.tekir.istanbul>.

## local preview

from the repo root:

```bash
python3 -m http.server 4173 --directory website
```

then open <http://localhost:4173>.

## structure

```
website/
  index.html        entry point
  styles.css        all styling
  assets/           static assets (favicon, wordmark, screenshots)
```

## assets

all images are deploy copies of canonical repository assets — edit the canonical source, regenerate, and copy here; never edit the copies:

- `assets/favicon.png` — copy of `assets/app-icon/web/favicon-32.png`
- `assets/tekir-wordmark-{ink,white}-h128.png` — copies of `assets/brand/temporary/exports/`
- `assets/screenshot-*.webp` — web exports of the approved captures in `assets/store/screenshots/source/` (01-map, 02-cat-detail, 04-discover-needs-help), regenerated from the repo root with:

```bash
python3 - <<'EOF'
from PIL import Image
pairs = [
    ("assets/store/screenshots/source/01-map.png", "website/assets/screenshot-map.webp"),
    ("assets/store/screenshots/source/02-cat-detail.png", "website/assets/screenshot-cat-detail.webp"),
    ("assets/store/screenshots/source/04-discover-needs-help.png", "website/assets/screenshot-needs-help.webp"),
]
for src, dst in pairs:
    im = Image.open(src).convert("RGB")
    im = im.resize((640, round(im.height * 640 / im.width)), Image.LANCZOS)
    im.save(dst, "WEBP", quality=82, method=6)
EOF
```

## validation

from the repo root. every referenced local asset must exist (no output means all paths resolve):

```bash
grep -oE '(src|srcset|href)="(assets/[^"]+|styles\.css)"' website/index.html \
  | cut -d'"' -f2 | sort -u \
  | while read -r p; do [ -f "website/$p" ] || echo "missing: $p"; done
```

every external link must respond (expect `200` per line):

```bash
grep -oE 'href="https?://[^"]+"' website/index.html | cut -d'"' -f2 | sort -u \
  | while read -r u; do curl -sIL -o /dev/null -w "%{http_code} $u\n" "$u"; done
```

## cloudflare deployment

- build command: none
- deploy command: `npx wrangler deploy`
- root directory: `website`
