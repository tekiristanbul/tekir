# cats

## goal

define the core thing shown on the map: the cat.

## decisions

- a cat can have many photos and videos over time. media is added through updates and forms a place-style gallery, similar to how map products collect location media.
- a cat cannot have more than one location. instead, a cat belongs to an area — roughly 50 meters around a point.
- every mvp cat record represents one individual cat. colonies or groups are not modeled.
- adding a cat should not be blocked by duplicate-detection warnings. if two people add what looks like the same cat, contribution continues; duplicate cats can be merged later through an admin workflow.
- duplicate merge selects one canonical cat, moves updates, media, and follows to it, and leaves a redirect or tombstone for the duplicate record. duplicate records are not silently hard-deleted.
- the cat's creator may soft-delete a cat they created by mistake (issue #200) — a terminal state in this version, with no restore/reactivate flow. moderator/admin-initiated deletion of a cat the caller doesn't own remains out of scope for this slice; see [[trust]].
- the minimum information to add a cat is a photo and a location. a user-provided name is optional.
- when no name is provided, the product may assign a friendly random name. photo-based ai name suggestions are a later enhancement, not an mvp requirement.
- the cat's creator may correct the name after creation (issue #199) — a recovery path for a naming mistake, not a general-purpose profile editor. no other cat field is editable through this path.
- every cat has exactly one canonical image, its **profile photo** (issue #236). the first photo uploaded when the cat is created becomes it. cat detail shows it as a circular avatar — there is no wide cover-photo area and no focal-point selection; a circle crops a portrait phone photo without distorting it, which the old 16:9 cover did badly. the cat's owner may promote any photo from the cat's own media archive to profile photo with "profil fotoğrafı yap"; nobody else can, and a video is never eligible. changing it moves only which image is canonical — the update and media it came from are untouched. existing cats keep the image they already had, with no re-upload and no migration.
- permanent personality traits are not collected during cat creation and are not treated as authoritative cat-profile data. different people may experience the same cat differently.
- behavioral observations such as playful, shy, or friendly belong in update comments ([[updates]]). future ai-generated summary labels may be derived from accumulated observations, but they must remain summaries rather than a single user's permanent classification.
- strongly identifying physical information should help users recognize that they opened the correct cat.
- the initial main cat image may come from a curated set of city-cat images.
- community-uploaded media never becomes the main profile image automatically in mvp. an admin may select a different main image later.
- cats are not automatically removed from the map because of inactivity.
- after 12 months without an update, a cat is presented as `long_not_seen`; this is a freshness state, not deletion or proof that the cat is gone.

## open questions

- none for mvp.

## out of scope

- automatic ai naming in mvp.
- restoring or reactivating a soft-deleted cat.
- moderator/admin-initiated deletion of a cat the caller doesn't own.
- permanent user-selected personality traits.
- colony or group records.
- automatic profile-image promotion.
