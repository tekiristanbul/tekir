-- name: UpsertWorkspacePing :one
insert into workspace_pings (id, message, location)
values ($1, $2, st_setsrid(st_makepoint(sqlc.arg(lng)::float8, sqlc.arg(lat)::float8), 4326))
on conflict (id) do update set message = excluded.message, location = excluded.location
returning id, message, st_x(location::geometry)::float8 as lng, st_y(location::geometry)::float8 as lat, created_at;

-- name: ListWorkspacePings :many
select id, message, st_x(location::geometry)::float8 as lng, st_y(location::geometry)::float8 as lat, created_at
from workspace_pings
order by created_at desc;
