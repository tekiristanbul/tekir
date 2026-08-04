-- +goose Up
-- issue #101 (contract: issue #100 / docs/product/alerts.md): help becomes a
-- boolean flag an update carries, combinable with ordinary statuses, instead
-- of a mutually-exclusive update subtype with a fixed category vocabulary.
-- Additive rollout: `kind` and `needs_help_category` are deliberately NOT
-- dropped — kind freezes into legacy metadata (only pre-migration rows and
-- restored-on-rollback rows ever hold 'needs_help'), and every stored
-- category value survives untouched, per the contract's "existing
-- category-bearing records must not be silently discarded" constraint. New
-- write paths always insert kind = 'ordinary'; the compat needs-help
-- endpoint still records the category a 0.1 client sends, as legacy
-- metadata only (never rendered by 0.2 clients).
alter table updates add column needs_help boolean not null default false;

-- backfill: every existing needs-help subtype row becomes a flag-bearing
-- row. Its category/expiry columns are untouched, so a rollback restores
-- the exact pre-migration shape bit-for-bit for these rows.
update updates set needs_help = true where kind = 'needs_help';

-- the old constraint tied category/expiry to kind; the new one ties them to
-- the flag. A category may only exist on a help-carrying row (legacy or
-- compat-endpoint writes); expiry must exist exactly when the flag is set —
-- "active" itself stays derived (expires_at vs. the service clock at read
-- time), never stored.
alter table updates drop constraint updates_kind_fields_ck;
alter table updates add constraint updates_needs_help_fields_ck check (
  (needs_help = false and needs_help_category is null and needs_help_expires_at is null)
  or
  (needs_help = true and needs_help_expires_at is not null)
);

-- the latest-help lookup (active-alert lateral joins, discover filter) now
-- selects on the flag, not the kind. Help-carrying rows are also deletable
-- and clearable within the author's 10-minute window as of this issue, so
-- the read paths that use this index additionally filter deleted_at — the
-- index stays partial on the flag alone, which those predicates narrow.
drop index updates_needs_help_idx;
create index updates_needs_help_idx on updates (cat_id, created_at desc, seq desc) where needs_help;

-- +goose Down
-- rollback restores the 0.1 model. Pre-migration data is restored exactly:
-- backfilled rows still hold kind = 'needs_help' + category + expiry, so
-- dropping the flag column returns them bit-for-bit. Rows written after the
-- migration cannot all exist in the 0.1 model, so:
--   * a post-migration help row that carries a category (written by the
--     compat needs-help endpoint) is representable — restore it to
--     kind = 'needs_help';
--   * a category-less help row (the new combined model) is not — the 0.1
--     schema has no way to express it. It is demoted to a plain ordinary
--     update: the row, its statuses, and its comment survive; only the help
--     aspect (expiry) is dropped. This bounded, documented loss is the cost
--     of rolling back, never of rolling forward.
alter table updates drop constraint updates_needs_help_fields_ck;

update updates set kind = 'needs_help'
where needs_help and needs_help_category is not null and kind = 'ordinary';

update updates set needs_help_expires_at = null
where needs_help and needs_help_category is null;

drop index updates_needs_help_idx;
create index updates_needs_help_idx on updates (cat_id, created_at desc, seq desc) where kind = 'needs_help';

alter table updates add constraint updates_kind_fields_ck check (
  (kind = 'ordinary' and needs_help_category is null and needs_help_expires_at is null)
  or
  (kind = 'needs_help' and needs_help_category is not null and needs_help_expires_at is not null)
);

alter table updates drop column needs_help;
