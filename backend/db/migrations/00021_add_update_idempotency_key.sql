-- +goose Up
-- issue #80 (product-owner review): the "Gördüm" one-tap shortcut had no
-- protection against a duplicate network retry or a fast double-tap
-- creating two identical ordinary updates. Mirrors the exact idempotency
-- pattern already established for cats.idempotency_key (migration 00017)
-- and media.idempotency_key (same migration): a client-generated opaque
-- string, scoped to the authenticated account, so a retried
-- POST /v1/cats/{cat_id}/updates with the same key returns the original
-- row instead of creating a second one. Scoped to kind = 'ordinary' only —
-- needs-help reports have their own fixed 72h lifecycle and never needed
-- this (docs/product/updates.md never described a "duplicate needs-help"
-- concern the way repeated "seen" taps raised one).
alter table updates add column idempotency_key text;

create unique index updates_user_idempotency_uq on updates (author_user_id, idempotency_key)
  where idempotency_key is not null and kind = 'ordinary';

-- +goose Down
drop index updates_user_idempotency_uq;
alter table updates drop column idempotency_key;
