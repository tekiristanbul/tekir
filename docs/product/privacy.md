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
- uploaded images are decoded and re-encoded before storage, which strips exif and other embedded metadata (including camera location) so it never reaches public storage.
- stored media objects live in publicly readable object storage under opaque random keys; keys never contain phone numbers, display names, cat names, comments, original filenames, coordinates, or account/device identifiers.
- precise device location is used only when necessary for map interaction or user-requested nearby discovery. it is not published as a user's location history.
- tekir does not sell personal data or expose private account data to advertisers.
- account deletion removes or anonymizes personal account information. public cat history and contributions remain, but are no longer associated with the deleted user's public identity.
- moderation and legal obligations may require retaining limited internal records for a defined operational period; such records are not public.
- a user-generated content report (issue #233, [[trust]]) is retained indefinitely — no auto-expiry or scheduled purge — since it is the only durable record of a moderation concern until a maintainer reviews it. a report is never public: no endpoint exposes another account's reports, or any report at all, to any client in this version. submitting a report never automatically hides or deletes the reported cat, update, or media; it only creates a record for a maintainer to review.
- notification permission is requested only after a user chooses to follow a cat or otherwise opts into notifications, not on first launch.
- product analytics ([[analytics]]) collects only anonymous, bounded behavioral events: no phone numbers, names, free text, cat names, precise location, tokens, or raw record ids are ever sent to the analytics provider, no analytics user id is set, and no advertising identifiers, audiences, or session replay are used.

## open questions

- none for mvp. implementation must define concrete retention periods and publish the legally reviewed privacy notice before public launch.

## out of scope

- private profiles.
- private cat records or private updates.
- advertising-based personalization.
- publishing a user's movement or precise location history.
