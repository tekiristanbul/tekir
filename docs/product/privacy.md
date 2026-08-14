# privacy

## goal

make it clear which information is public, which information remains private, and why tekir collects it.

## decisions

- browsing public cats, map information, updates, comments, help alerts, and public media does not require an account.
- a phone number is collected only for authentication, account recovery, abuse prevention, and account ownership verification.
- phone numbers are never public and are not included in public api responses.
- raw device tokens, push tokens, refresh tokens, and internal device identifiers are never public.
- a user's display name, selected profile avatar, earned badges, contribution totals, and public contribution history are public.
- cat records, updates, help alerts, comments, and uploaded media are public because the product depends on shared city information.
- uploaded media may contain location or contextual information; the upload flow must explain that accepted media becomes publicly visible.
- uploaded images are decoded and re-encoded before storage, which strips exif and other embedded metadata (including camera location) so it never reaches public storage. the one exception read before that strip: a jpeg's exif orientation tag is applied as a pixel transform (issue #237) so the stored image is upright — the tag's *value* is used, never retained.
- stored media objects live in publicly readable object storage under opaque random keys; keys never contain phone numbers, display names, cat names, comments, original filenames, coordinates, or account/device identifiers.
- precise device location is used only when necessary for map interaction or user-requested nearby discovery. it is not published as a user's location history.
- tekir does not sell personal data or expose private account data to advertisers.
- account deletion removes or anonymizes personal account information. public cat history and contributions remain, but are no longer associated with the deleted user's public identity.
- moderation and legal obligations may require retaining limited internal records for a defined operational period; such records are not public.
- a user-generated content report (issue #233, [[trust]]) is retained indefinitely — no auto-expiry or scheduled purge — since it is the only durable record of a moderation concern until a maintainer reviews it. a report is never public: no endpoint exposes another account's reports, or any report at all, to any client in this version. submitting a report never automatically hides or deletes the reported cat, update, or media; it only creates a record for a maintainer to review.
- a block (issue #234, [[trust]]) is private to the account that created it: `GET /v1/me/blocks` is the only read that returns blocks and it is always scoped to the caller, so no endpoint tells anyone that they have been blocked, or by whom. a block row stores nothing beyond the two account ids and a timestamp — no reason, no note, no free text. unblocking deletes the row outright rather than retaining a history of past blocks.
- an authenticated user can delete their account from inside the app (issue #242, apple guideline 5.1.1(v)). deletion is terminal — there is no deactivation or restore — and it removes the account and its identity, its auth/session state, its follows, the updates it wrote, the media it uploaded (database rows and the stored files), and the cats it created, along with everything attached to those cats. other people's contributions to a deleted user's cats go with those cats: preserving or reassigning them is follow-up work, not a 0.4 behavior. the phone number is released with the account, including any outstanding one-time codes, so registering it again later starts a genuinely new account. the app clears its local credentials only after the server confirms the deletion.
- notification permission is requested only after a user chooses to follow a cat or otherwise opts into notifications, not on first launch.
- product analytics ([[analytics]]) collects only anonymous, bounded behavioral events: no phone numbers, names, free text, cat names, precise location, tokens, or raw record ids are ever sent to the analytics provider, no analytics user id is set, and no advertising identifiers, audiences, or session replay are used.

## open questions

- none for mvp. implementation must define concrete retention periods and publish the legally reviewed privacy notice before public launch.

## out of scope

- private profiles.
- private cat records or private updates.
- advertising-based personalization.
- publishing a user's movement or precise location history.
