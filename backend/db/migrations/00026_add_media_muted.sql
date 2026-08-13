-- +goose Up
-- issue #194: short-form videos default to muted. `muted` is set by the
-- uploader at POST /v1/media (defaulting true when the client sends
-- nothing) and stored per media row rather than derived — a photo's value
-- is meaningless but harmless, kept true like everything else uploaded
-- without an explicit override. No transcoding happens on write
-- (docs/architecture/backend.md's "no transcoding, stored as-is" decision
-- stands): the object's own audio track is untouched regardless of this
-- flag, which only gates whether the app's playback surfaces expose it —
-- see docs/architecture/backend.md for the accepted limitation this
-- implies for direct object-url access.
alter table media add column muted boolean not null default true;

-- +goose Down
alter table media drop column muted;
