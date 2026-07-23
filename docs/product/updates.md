# updates

## goal

define how information about a cat stays current.

## decisions

- updates are structured status updates, not free-form "comments" — but a user can add their own free-text comment along with a status update.
- an update has two parts: one or more structured statuses, then an optional comment in the same update. this can be shown on the cat's detail page.
- an update requires at least one structured status; the comment alone is not enough.
- the initial structured-status vocabulary is `seen`, `fed`, and `water_provided` (approved for mvp). a "still here" status was considered and rejected — `seen` plus the update's own timestamp already carries that meaning.
- behavioral traits like "friendly" or "playful" are not status-update content — they belong to the cat's profile ([[cats]]), not to an individual update.
- updates can be posted without a photo.
- all updates are shown, newest first — not just the latest one.

## open questions

- how old information should expire is not decided. one idea: cats with no update for about 1 year. flagged as a topic for later.

## out of scope

- not discussed further in this part of the workshop.
