# visual direction

## goal

give whoever builds the real figma file a concrete starting point instead of a blank canvas. this is a direction, not a finished visual identity — the wireframes in [[wireframes]] are structural and intentionally placeholder-grade; this is what should replace that placeholder.

## decisions

### color

grounded in the actual subject — istanbul street cats are mostly noticed in the evening, around streetlight-lit corners and shopfronts, not in daylight studio conditions. the palette leans into that instead of a generic bright "app" look.

| token | hex | use |
|---|---|---|
| ink (night) | `#14181f` | primary text, dark surfaces |
| paper (overcast sky) | `#eef0f0` | light background — cool-tinted, not warm cream |
| panel | `#ffffff` | cards, sheets |
| accent (streetlamp amber) | `#d9862a` | needs-help state, primary actions, follow indicator — used sparingly, one accent only |
| line (asphalt) | `#9aa1a6` | borders, dividers |

dark mode isn't an inversion — it leans further into the "night streets" idea: ink becomes the background (`#0e1116`), amber brightens slightly (`#eda63f`) so it still reads as a glow against dark, not a flat swatch.

### type

two roles, deliberately not inter/space grotesk (too common a default to read as considered):

- **display** (app name, screen titles, cat names): `Fraunces` — a warm, slightly characterful serif. gives cats/places some personality without tipping into "elegant editorial" territory.
- **body/ui** (buttons, labels, update text): `Work Sans` — humanist grotesk, warm but neutral, holds up at small sizes on both material and ios.
- both need self-hosting (bundled with the app / embedded as data uris on the web), not a font-cdn dependency.

### tone / imagery

- cat-first, per [[principles]]: photos are the hero, chrome stays quiet. no illustration style, no cartoon cats — real photos only.
- user-submitted photos are shown as-is, not filtered or over-processed — the point is authenticity of a specific cat, not editorial gloss.
- the map is a tool, not a decoration ([[map]]): keep tile styling muted so pins and photos are what draws the eye.

## open questions

- nothing here has been through actual figma exploration yet — treat every value above as a first draft, not a locked decision.
- iconography style (outline vs. filled, weight) isn't decided.

## out of scope

- a finished component library / design system in figma — that's the next real step, not this document.
- logo/wordmark design.
