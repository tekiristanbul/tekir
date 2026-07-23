-- name: ListActiveTraits :many
-- the selectable vocabulary: what the future grouped multi-select picker
-- (product-owner decision on issue #21/#23) renders as options, ordered
-- group-then-trait so a client can render section headers without its own
-- sort pass. retired (active=false) traits are excluded here but not from
-- ListCatTraits, so a cat that already carries a retired trait keeps
-- showing it. a trait with no group (group_key null) sorts after every
-- grouped trait rather than interleaving arbitrarily.
select t.key, t.display_name, t.group_key, g.display_name as group_display_name
from traits t
left join trait_groups g on g.key = t.group_key
where t.active
order by coalesce(g.sort_order, 2147483647), t.sort_order, t.key;

-- name: ListCatTraits :many
-- joins the vocabulary (and its group) so cat detail can render a display
-- label without a separate vocabulary fetch. intentionally not filtered by
-- traits.active: retiring a trait must not erase a cat's existing,
-- historical association.
select t.key, t.display_name, t.group_key, g.display_name as group_display_name
from cat_traits ct
join traits t on t.key = ct.trait_key
left join trait_groups g on g.key = t.group_key
where ct.cat_id = sqlc.arg(cat_id)
order by coalesce(g.sort_order, 2147483647), t.sort_order, t.key;

-- name: CreateCatTrait :exec
-- no endpoint sets this yet — trait selection is out of scope for issue #21
-- and belongs to the future add/edit-cat flow. used by seed data only.
insert into cat_traits (cat_id, trait_key)
values (sqlc.arg(cat_id), sqlc.arg(trait_key))
on conflict (cat_id, trait_key) do nothing;

-- name: UpsertTrait :one
-- loads/updates the vocabulary itself (seed data only for now — there's no
-- admin endpoint). upserting on key lets seed re-runs adjust display_name/
-- group_key/sort_order/active in place instead of erroring on a duplicate key.
insert into traits (key, display_name, group_key, active, sort_order)
values (sqlc.arg(key), sqlc.arg(display_name), sqlc.arg(group_key), sqlc.arg(active), sqlc.arg(sort_order))
on conflict (key) do update set
  display_name = excluded.display_name,
  group_key = excluded.group_key,
  active = excluded.active,
  sort_order = excluded.sort_order
returning key;

-- name: UpsertTraitGroup :one
-- loads/updates the group vocabulary (seed data only, same rationale as
-- UpsertTrait).
insert into trait_groups (key, display_name, sort_order)
values (sqlc.arg(key), sqlc.arg(display_name), sqlc.arg(sort_order))
on conflict (key) do update set
  display_name = excluded.display_name,
  sort_order = excluded.sort_order
returning key;
