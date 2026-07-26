-- +goose Up
-- issue #58: the approved prototype's new-account step collects a public
-- display name before finishing sign-in (prototype/app.js's "Görünen
-- adını seç" step). nullable — set once, shortly after account creation,
-- via PATCH /v1/me (see [[api]]); a returning account never has this
-- column touched again by this issue's scope. no uniqueness constraint:
-- multiple accounts may share a display name, matching the prototype.
alter table users add column display_name text;

-- +goose Down
alter table users drop column display_name;
