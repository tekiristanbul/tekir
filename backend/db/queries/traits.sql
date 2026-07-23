-- name: ListActiveTraits :many
-- the selectable vocabulary: what a future add/edit-cat flow renders as
-- options. retired (active=false) traits are excluded here but not from
-- ListCatTraits, so a cat that already carries a retired trait keeps
-- showing it.
select key, display_name
from traits
where active
order by sort_order, key;

-- name: ListCatTraits :many
-- joins the vocabulary so cat detail can render a display label without a
-- separate vocabulary fetch. intentionally not filtered by traits.active:
-- retiring a trait must not erase a cat's existing, historical association.
select t.key, t.display_name
from cat_traits ct
join traits t on t.key = ct.trait_key
where ct.cat_id = sqlc.arg(cat_id)
order by t.sort_order, t.key;

-- name: CreateCatTrait :exec
-- no endpoint sets this yet — trait selection is out of scope for issue #21
-- and belongs to the future add/edit-cat flow. used by seed data only.
insert into cat_traits (cat_id, trait_key)
values (sqlc.arg(cat_id), sqlc.arg(trait_key))
on conflict (cat_id, trait_key) do nothing;

-- name: UpsertTrait :one
-- loads/updates the vocabulary itself (seed data only for now — there's no
-- admin endpoint). upserting on key lets seed re-runs adjust display_name/
-- sort_order/active in place instead of erroring on a duplicate key.
insert into traits (key, display_name, active, sort_order)
values (sqlc.arg(key), sqlc.arg(display_name), sqlc.arg(active), sqlc.arg(sort_order))
on conflict (key) do update set
  display_name = excluded.display_name,
  active = excluded.active,
  sort_order = excluded.sort_order
returning key;
