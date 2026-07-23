-- +goose Up
-- human-readable, display-only location label (issue #21 prototype-parity
-- correction). nullable and free text: there's no runtime reverse-geocoding
-- service, so this is set once at cat-creation/seed time, not derived from
-- lat/lng on every read. raw coordinates stay in `area`; this column is
-- purely what a user sees ("Moda Sahili, Kadıköy"), never parsed back into
-- geography.
alter table cats add column area_label text;

-- +goose Down
alter table cats drop column area_label;
