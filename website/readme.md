# website

the public landing page for tekir: `index.html` + `styles.css`, no build step, no framework, no dependency on the api or the flutter app.

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
  styles.css         all styling
  assets/            static assets (e.g. the map preview screenshot)
```

## cloudflare deployment

- build command: none
- deploy command: `npx wrangler deploy`
- root directory: `website`
