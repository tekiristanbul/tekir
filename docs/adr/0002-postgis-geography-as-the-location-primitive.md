# 0002. postgis `geography(point, 4326)` as the location primitive

- status: accepted
- date: 2026-08-19
- source: `docs/architecture/db.md` (schema, design notes),
  `backend/db/migrations/00001_enable_extensions.sql`,
  `backend/db/migrations/00003_create_cats.sql`
- supersedes: —

## context

every primary surface in tekir is location-bound: the map queries a viewport, the
add-cat flow checks for a duplicate within ~50 m, and discovery orders cats by
distance from the caller. [`docs/product/cats.md`](../product/cats.md) describes a
cat as belonging to an *area* of roughly 50 m rather than to an exact coordinate.

## decision

a cat's location is one column, `cats.area geography(point, 4326)`, indexed by
`cats_area_gix` (gist). postgis is enabled as a database extension
(migration `00001`) and every geo predicate is a postgis function evaluated in
the database: `st_dwithin` for the duplicate check, `st_distance` for
distance-ordered discovery, and a bounding-box predicate for the map.

srid 4326 (wgs84) is the storage and wire coordinate reference system. the api
carries coordinates as plain `{lat, lng}` numbers and a bounding box as
`?bbox=minLng,minLat,maxLng,maxLat`.

the product's "area" concept is expressed at query time — `st_dwithin(area,
point, 50)` — not as a stored radius or a separate area table.

## alternatives considered

- **a separate area table.** rejected in `docs/architecture/db.md`: it adds a
  table and a join without producing any behavior the point plus a query-time
  radius does not already give.
- **plain float latitude/longitude columns with distance computed in go.**
  rejected implicitly by choosing postgis and a gist index: the map, duplicate
  check, and distance-ordered discovery all need the database to filter and
  order before it pages, which application-side math cannot do.

## consequences

- postgres alone is not enough to run tekir. local development, ci, and
  production all need the postgis extension — ci runs
  `postgis/postgis:17-3.5-alpine` as a service container for exactly this
  reason, and a managed postgres provider without postgis is not a viable host.
- distance-ordered endpoints paginate on `(distance_m, id)` keyset, which forces
  the computed distance into a cte so the `order by` and the keyset predicate
  read the identical value.
- the api exposes coordinates in a bespoke flat shape rather than geojson. every
  consumer hand-writes its own parsing, and adding a geojson representation
  later is an additive api change, not a storage change — the storage is already
  standard wgs84.
