-- +goose Up
-- issue #200: owner-initiated cat deletion is a terminal soft-delete state,
-- not a hard delete — no cat/media/update row is ever physically removed.
-- 'deleted' joins the existing status vocabulary rather than getting its
-- own column: every read path that already filters `status = 'active'`
-- (ListCatsInBounds/ListNearbyCatsForDuplicateCheck/ListCatsByDistance/
-- ListActiveNeedsHelpCatsByDistance, see docs/architecture/db.md) excludes
-- a deleted cat automatically, no query change needed there. There is
-- deliberately no restore/reactivate path in this version, so no schema
-- support for moving back out of 'deleted' is added either.
alter table cats drop constraint cats_status_check;
alter table cats add constraint cats_status_check check (status in ('active', 'inactive', 'deleted'));

-- +goose Down
-- rollback is safe only while no row actually holds 'deleted' — restoring
-- the narrower constraint over existing 'deleted' rows would leave the
-- table violating its own check constraint, so this fails loudly instead
-- of silently corrupting data.
alter table cats drop constraint cats_status_check;
alter table cats add constraint cats_status_check check (status in ('active', 'inactive'));
