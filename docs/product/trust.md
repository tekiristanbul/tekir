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
- the product should not block cat creation with duplicate-detection warnings. duplicate correction and merging happen later through admin or moderator tools.
- trust is expressed through authenticated, visible, public contribution history rather than follower counts or people-centric popularity.

## open questions

- how a "trusted contributor" is defined is not decided.

## out of scope

- people-following.
- public popularity ranking or leaderboards in mvp.
