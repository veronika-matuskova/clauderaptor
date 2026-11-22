# Global instructions (applies to every repo)

Rule files in `rules/` are loaded automatically; add global notes that are not rules here.

- Docker is Docker Engine inside WSL (set up by clauderaptor's `scripts/setup/setup-docker.sh`), not Docker Desktop. The daemon is socket-activated: just run `docker` / `docker compose` and the first call starts it, without sudo. If `docker info` still fails, show the user the error instead of skipping work that needs Docker.
