# Podman

Daemonless, rootless container engine — a drop-in replacement for Docker with the same CLI, no background daemon, and no root required. The default on RHEL/Fedora.

### Why Podman over Docker

- **Daemonless** — there's no always-on `dockerd`. Each `podman` command runs directly, so nothing runs as root in the background and there's no single daemon to crash.
- **Rootless by default** — containers run as _your_ user. A container breakout lands in your unprivileged account, not root.
- **Docker-compatible CLI** — the commands and flags are identical. `alias docker=podman` covers most day-to-day use (or install the `podman-docker` package for a real `docker` shim).
- **systemd-native** — Podman is built to run containers as systemd services (see [systemd/](../systemd/README.md)).

> **Pro-Tip:** Everywhere you'd type `docker`, type `podman`. `podman run`, `podman ps`, `podman build` — same flags, same behavior.

## Container lifecycle

Command pattern: `podman run [flags] IMAGE [command]`.

| Action       | Command                                      | What it does                                                              |
| ------------ | -------------------------------------------- | ------------------------------------------------------------------------- |
| **Run**      | `podman run -d --name web -p 8080:80 nginx`  | Create + start a container from an image (detached, named, port-mapped).  |
| **List**     | `podman ps`                                  | Show running containers. Add `-a` to include stopped ones.                |
| **Logs**     | `podman logs -f web`                         | Stream a container's output (`-f` follows, like `tail -f`).               |
| **Shell in** | `podman exec -it web bash`                   | Open an interactive shell inside a _running_ container.                   |
| **Stop**     | `podman stop web`                            | Gracefully stop a running container.                                      |
| **Start**    | `podman start web`                           | Restart a stopped container (keeps its original config).                  |
| **Remove**   | `podman rm -f web`                           | Delete a container. `-f` force-removes even if it's still running.        |

Flags you'll reach for on `run`:

- `-d` detached (background) &nbsp;·&nbsp; `-it` interactive + TTY (for shells)
- `--name web` name it &nbsp;·&nbsp; `--rm` auto-delete when it exits
- `-p 8080:80` publish `host:container` port &nbsp;·&nbsp; `-e KEY=val` set an env var
- `-v ./data:/data:Z` bind-mount a dir (`:Z` relabels it for SELinux — needed on RHEL)

## Images

| Action      | Command                               | What it does                                                            |
| ----------- | ------------------------------------- | ----------------------------------------------------------------------- |
| **Pull**    | `podman pull docker.io/library/nginx` | Download an image from a registry.                                      |
| **List**    | `podman images`                       | Show images stored locally.                                            |
| **Build**   | `podman build -t myapp .`             | Build an image from a `Containerfile` (or `Dockerfile`) in this dir.    |
| **Remove**  | `podman rmi myapp`                    | Delete a local image.                                                   |
| **Prune**   | `podman system prune`                 | Reclaim space — remove stopped containers, unused images, dangling data.|

> **Pro-Tip:** Podman doesn't assume Docker Hub. Use fully-qualified names (`docker.io/library/nginx`) or set `unqualified-search-registries` in `/etc/containers/registries.conf`.

## Pods — the namesake feature

A **pod** groups one or more containers that share a network namespace — they reach each other over `localhost`, exactly like a Kubernetes pod.

| Action            | Command                                     | What it does                                              |
| ----------------- | ------------------------------------------- | -------------------------------------------------------- |
| **Create**        | `podman pod create --name app -p 8080:80`   | Create an empty pod; publish ports at the _pod_ level.   |
| **Add container** | `podman run -d --pod app nginx`             | Start a container inside the pod (shares its network).   |
| **List**          | `podman pod ps`                             | Show pods and how many containers each holds.            |
| **Stop / Start**  | `podman pod stop app` / `podman pod start app` | Stop or start every container in the pod at once.     |
| **Remove**        | `podman pod rm -f app`                       | Delete the pod and all of its containers.                |

> **Pro-Tip:** `podman generate kube app > app.yaml` exports a running pod as a Kubernetes manifest, and `podman play kube app.yaml` runs one. Handy for prototyping K8s locally.

## Run containers as systemd services

The modern way is **Quadlet**: drop a `.container` file and let systemd manage the container as a normal service. Rootless units live in `~/.config/containers/systemd/`.

`~/.config/containers/systemd/web.container`:

```ini
[Container]
Image=docker.io/library/nginx:latest
PublishPort=8080:80

[Install]
WantedBy=default.target
```

Then reload and start it — the unit name is the filename (`web.container` → `web.service`):

```bash
systemctl --user daemon-reload
systemctl --user start web
```

> **Rule of thumb:** after editing any Quadlet file, run `systemctl --user daemon-reload` — the same daemon-reload trap that applies to every other unit file.

Two gotchas for rootless _user_ services:

- **Linger** — user services die when you log out unless lingering is enabled: `loginctl enable-linger $USER`.
- **`--user`** — rootless containers are _user_ units. Drop `--user` (and put the file in `/etc/containers/systemd/`) only for root-owned system containers.

> The older `podman generate systemd` is deprecated in favor of Quadlet, but still works on older Podman versions.

## Gotchas vs. Docker

- **Low ports** — rootless can't bind ports below 1024 by default. Publish a high port (`-p 8080:80`), or lower the threshold: `sudo sysctl net.ipv4.ip_unprivileged_port_start=80`.
- **compose** — `podman compose` delegates to an external provider; install `podman-compose` for `docker-compose.yml` support.
- **SELinux** — on RHEL, bind mounts need a `:Z` (private) or `:z` (shared) suffix or the container can't read them.
- **macOS / Windows** — there's no native Linux kernel, so Podman runs a VM. Bootstrap it once: `podman machine init && podman machine start`.
