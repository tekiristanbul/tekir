# trust

## goal

define what makes the product's information reliable without making contribution unnecessarily difficult.

## decisions

- the guiding principle is: contribution should be easy, but every contribution must remain attributable to an authenticated account.
- guests (not logged in) can view cats on the map, read updates and comments, and see labels.
- following/favoriting a cat requires an authenticated account ([[notifications]]).
- posting any update requires a phone-verified authenticated account. this includes ordinary structured-status updates and needs-help updates.
- adding photos or videos and adding a new cat also require a phone-verified authenticated account.
- a cat's own creator may soft-delete it (issue #200, [[cats]]) — a terminal state with no restore/reactivate flow. deleting a cat the caller doesn't own remains an out-of-scope moderator/admin action.
- users may correct or remove their own update only during the short grace period defined by the update experience ([[updates]]). after that, newer updates provide the current state.
- an authenticated account may report a cat, an update, or a media item for a fixed reason (issue #233, [[api]]/[[db]]). reporting is narrow, not a moderation platform: a report never automatically hides or deletes content, there is no public moderation queue, no automated/ai classification, no reputation or user-penalty effect, and no automatic hide-after-N-reports behavior. it exists so maintainers can review and act on flagged content by hand — a 0.4 admin/moderator dashboard is explicitly out of scope; report records persist ([[privacy]]) for that future review, not for any 0.4-visible effect.
- an authenticated account may block another account (issue #234, [[api]]/[[db]]). blocking is a personal visibility control, not a moderation action: it hides, for the blocker only, every cat the blocked account owns and everything attached to those cats — markers, detail, updates, media, and other people's contributions on them. it deletes nothing, penalises nobody, and is invisible to the blocked account, which is never notified and cannot detect it. it is reversible at any time from "engellenen hesaplar", and unblocking restores exactly what was hidden, follows included. blocking is owner-scoped by product decision: it does not hide the blocked account's updates or media on cats someone else owns. enforcement is server-side on every read — a hidden cat answers exactly like an unknown one, so the product never reveals that something exists and was filtered.
- the product should not block cat creation with duplicate-detection warnings. duplicate correction and merging happen later through admin or moderator tools.
- trust is expressed through authenticated, visible, public contribution history rather than follower counts or people-centric popularity.

## open questions

- how a "trusted contributor" is defined is not decided.

## out of scope

- people-following.
- public popularity ranking or leaderboards in mvp.
