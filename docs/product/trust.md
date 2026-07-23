# trust

## goal

define what makes the product's information reliable.

## decisions

- guests (not logged in) can view cats on the map, read comments and updates, and see labels.
- guests can also follow a cat and post a text-only update (no photo/video) without logging in. this revises the original decision below — logging in is required only for adding a photo or video, which includes adding a new cat, since a photo is mandatory there. the reasoning: contribution friction should scale with risk (a photo/video is the abuse vector phone verification exists for), not apply uniformly to every action.
- phone verification is required for users who add photos, and for users who add a new cat (a photo is required when a cat is first added). this is so the team can identify or block abusive users, for example someone uploading inappropriate content.
- creating a needs-help alert ([[alerts]]) always requires being logged in, even though it carries no photo — an exception to "friction scales with photo/video risk" above. a false or spammy help alert has an outsized cost (it pages every follower), so this one action is authenticated regardless of media.
- wrong information gets corrected by users posting new updates, not by editing or deleting old ones.

## open questions

- how a "trusted contributor" is defined is not decided. some context was shared but not a decision: cat-feeding is common and localized in turkey — for example, 20-30 cats within 1km of one person's home, usually staying in the same spots and fed regularly by locals.

## out of scope

- not discussed further in this part of the workshop.
