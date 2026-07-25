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
- a needs-help alert ([[alerts]]) is a distinct subtype of the same update history. it must show the reason clearly, such as injured, hungry, needs water, unsafe location, or trapped, so a person can understand the need quickly.
- successful contributions receive lightweight, non-blocking feedback such as a short toast or tooltip. the feedback should encourage contribution without interrupting the flow.
- ordinary `seen`, `fed`, and `water_provided` updates do not trigger push notifications in mvp. active needs-help updates are the only update type that creates a push notification for followers ([[notifications]]).

## open questions

- none for mvp.

## out of scope

- permanent personality labels manually selected by users.
- ai-generated observation summaries in mvp.
- editing or deleting an update after the 10-minute correction window.
