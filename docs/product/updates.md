# updates

## goal

define how information about a cat stays current and leads to practical help.

## decisions

- an update records a contribution or observation about a cat.
- the initial structured-status vocabulary is `seen`, `fed`, and `water_provided` (approved for mvp).
- `seen` should be available as a one-tap action. a note or photo is not required.
- an update may contain one or more structured statuses plus an optional free-text comment.
- behavioral observations such as playful, shy, or friendly belong in the update comment. they are observations from a moment and a person, not permanent cat-profile traits ([[cats]]).
- updates can be posted without a photo.
- posting any update requires an authenticated account ([[trust]]).
- all updates are shown newest first on the cat timeline.
- ordinary updates never expire or disappear from history.
- old updates lose prominence through freshness presentation rather than deletion or semantic expiry.
- an update can receive comments so people can discuss or clarify that specific observation or contribution.
- users may correct or remove their own update for exactly 10 minutes after posting. after that window, history is immutable to ordinary users and newer updates provide the current state.
- a needs-help alert ([[alerts]]) is part of the same update history. since 0.2 (issue #100 contract; api/data model implemented by #101) `yardıma ihtiyacı var` is one of the options in the update screen, selectable alongside `gördüm`, `mama verdim`, and `su verdim` in a single update that appears as one timeline event; the reason lives in the reporter's optional free-text note, there are no help subcategories, and the 0.1 category vocabulary survives only as legacy metadata on old records.
- the 10-minute correction window extends to the help mark (product-owner decision on issue #101): its author may remove the mark — alone, or with the whole update — within the window; a correction can never add the mark after the fact. legacy pre-0.2 help records remain non-correctable.
- successful contributions receive lightweight, non-blocking feedback such as a short toast or tooltip. the feedback should encourage contribution without interrupting the flow.
- ordinary `seen`, `fed`, and `water_provided` updates do not trigger push notifications in mvp. active needs-help updates are the only update type that creates a push notification for followers ([[notifications]]).

## open questions

- none for mvp.

## out of scope

- permanent personality labels manually selected by users.
- ai-generated observation summaries in mvp.
- editing or deleting an update after the 10-minute correction window.
