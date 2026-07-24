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
- all updates are shown newest first on the cat timeline.
- an update can receive comments so people can discuss or clarify that specific observation or contribution.
- users may correct or remove their own update during a short grace period after posting. the exact duration is not a product requirement yet; it should be short enough to fix accidental taps without making old history continuously editable.
- a needs-help alert ([[alerts]]) is a distinct subtype of the same update history. it must show the reason clearly, such as injured, hungry, needs water, or missing, so a person can understand the need quickly.
- successful contributions receive lightweight, non-blocking feedback such as a short toast or tooltip. the feedback should encourage contribution without interrupting the flow.

## open questions

- the exact edit/delete grace period is not decided.
- how old information should expire is not decided.
- whether every followed-cat update should trigger a notification is not decided ([[notifications]]).

## out of scope

- permanent personality labels manually selected by users.
- ai-generated observation summaries in mvp.
