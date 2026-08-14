FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/api ./cmd/api

# issue #241 requires shelling out to a real ffmpeg binary for video
# moderation frame extraction — gcr.io/distroless/static-debian12 (the prior
# base) ships no package manager and no shared libraries, so it can't host
# ffmpeg's dynamic dependencies. debian:12-slim trades some of that minimal
# attack surface for a real, auditable apt install of ffmpeg from Debian's
# own repositories (see docs/architecture/backend.md's moderation note for
# the alternatives considered).
FROM debian:12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r -g 65532 nonroot \
    && useradd -r -u 65532 -g nonroot nonroot
COPY --from=build /out/api /api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/api"]
