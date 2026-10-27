# Ops notes: podman, systemd, journalctl

> **TODO: move this out of the repo.** These are generic cheat sheets. They
> describe podman and systemd, not this repo, and reference nothing in it --
> the same argument that removed `nvim/doc/dotfiles-motions.txt`. They are
> parked here, in one file, until they have a home: either the notes side of
> `my-machines`, or they become the seed of an ops section in `deps.conf`
> that declares real tools (`podman-tui`, `isd`, `k9s`) plus shortcut
> functions in the `gchecko` style, at which point the prose goes and the
> section's `deps.sh` and `h` pages carry what is left. Do not grow this
> file; move it.

---

## Podman

Daemonless, rootless container engine — a drop-in replacement for Docker with the same CLI, no background daemon, and no root required. The default on RHEL/Fedora.

### Why Podman over Docker

- **Daemonless** — there's no always-on `dockerd`. Each `podman` command runs directly, so nothing runs as root in the background and there's no single daemon to crash.
- **Rootless by default** — containers run as _your_ user. A container breakout lands in your unprivileged account, not root.
- **Docker-compatible CLI** — the commands and flags are identical. `alias docker=podman` covers most day-to-day use (or install the `podman-docker` package for a real `docker` shim).
- **systemd-native** — Podman is built to run containers as systemd services (see [systemd/](#systemd)).

> **Pro-Tip:** Everywhere you'd type `docker`, type `podman`. `podman run`, `podman ps`, `podman build` — same flags, same behavior.

### Container lifecycle

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

### Images

| Action      | Command                               | What it does                                                            |
| ----------- | ------------------------------------- | ----------------------------------------------------------------------- |
| **Pull**    | `podman pull docker.io/library/nginx` | Download an image from a registry.                                      |
| **List**    | `podman images`                       | Show images stored locally.                                            |
| **Build**   | `podman build -t myapp .`             | Build an image from a `Containerfile` (or `Dockerfile`) in this dir.    |
| **Remove**  | `podman rmi myapp`                    | Delete a local image.                                                   |
| **Prune**   | `podman system prune`                 | Reclaim space — remove stopped containers, unused images, dangling data.|

> **Pro-Tip:** Podman doesn't assume Docker Hub. Use fully-qualified names (`docker.io/library/nginx`) or set `unqualified-search-registries` in `/etc/containers/registries.conf`.

### Pods — the namesake feature

A **pod** groups one or more containers that share a network namespace — they reach each other over `localhost`, exactly like a Kubernetes pod.

| Action            | Command                                     | What it does                                              |
| ----------------- | ------------------------------------------- | -------------------------------------------------------- |
| **Create**        | `podman pod create --name app -p 8080:80`   | Create an empty pod; publish ports at the _pod_ level.   |
| **Add container** | `podman run -d --pod app nginx`             | Start a container inside the pod (shares its network).   |
| **List**          | `podman pod ps`                             | Show pods and how many containers each holds.            |
| **Stop / Start**  | `podman pod stop app` / `podman pod start app` | Stop or start every container in the pod at once.     |
| **Remove**        | `podman pod rm -f app`                       | Delete the pod and all of its containers.                |

> **Pro-Tip:** `podman generate kube app > app.yaml` exports a running pod as a Kubernetes manifest, and `podman play kube app.yaml` runs one. Handy for prototyping K8s locally.

### Run containers as systemd services

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

### Gotchas vs. Docker

- **Low ports** — rootless can't bind ports below 1024 by default. Publish a high port (`-p 8080:80`), or lower the threshold: `sudo sysctl net.ipv4.ip_unprivileged_port_start=80`.
- **compose** — `podman compose` delegates to an external provider; install `podman-compose` for `docker-compose.yml` support.
- **SELinux** — on RHEL, bind mounts need a `:Z` (private) or `:z` (shared) suffix or the container can't read them.
- **macOS / Windows** — there's no native Linux kernel, so Podman runs a VM. Bootstrap it once: `podman machine init && podman machine start`.

---

## Systemd

Way of managing Linux systems.

### Units

- Everything is a "Unit"

Instead of writing messy bash scripts to start services, `systemd` uses standardized configuration files called Unit Files.

### Types of Units

- `.service` - _tells the system what to do_
- `.timer` - _tells the system when to do it_
- `.path` - _triggers the system on filesystem activity_
- `.mount`

### systemctl

Command Pattern:

```bash
sudo systemctl [action] [service_name]
```

> You usually need `sudo` because you are changing system-wide states

You only need to memorize these actions to do 95% of your daily tasks. Let's use `nginx` (a popular web server) as our example service:

| Action      | Command                        | What it does                                                                                      |
| ----------- | ------------------------------ | ------------------------------------------------------------------------------------------------- |
| **Status**  | `systemctl status nginx`       | Checks if the service is currently running, crashed, or stopped. It also shows recent error logs. |
| **Start**   | `sudo systemctl start nginx`   | Turns the service on right now.                                                                   |
| **Stop**    | `sudo systemctl stop nginx`    | Turns the service off right now.                                                                  |
| **Restart** | `sudo systemctl restart nginx` | Stops and immediately starts the service. (Crucial for applying new configuration changes).       |
| **Enable**  | `sudo systemctl enable nginx`  | Tells the system to start this service automatically every time the server boots up.              |
| **Disable** | `sudo systemctl disable nginx` | Stops the service from starting automatically at boot.                                            |

### `start` vs. `enable`

- `start` turns the program on right now, but doesn't restart after reboot.
- `enable` queues the program to turn on automatically at boot, _but not right now_.

> **Pro-Tip:** If you want to turn a service unit on and make sure it survives reboot:

```bash
sudo systemctl enable --now [service_name]
```

### `restart` vs. `reload`

While `restart` is great, it uses brute force. It completely kills the process and starts it again, which will drop any active user connections. Many services (like web servers) support a gentler option:

- **Reload** (`sudo systemctl reload nginx`): Tells the service to re-read its configuration files _without_ shutting down or dropping active connections. Always prefer `reload` over `restart` if you just changed a config file!

### The "Daemon-Reload" Trap

If you ever create a brand new unit file (like a `.service` or `.timer`) or edit an existing one, `systemd` will not automatically know about your changes. If you try to start the service, you will get an error or it will run the old version.

You must tell `systemd` to rescan all of its unit files on the disk:

```bash
sudo systemctl daemon-reload
```

> **Rule of thumb:** If you open a `.service` file in `nano` or `(n)vim` and save, your very next command must be `systemctl daemon-reload`.

---

#### List `.service` units

```bash
systemctl list-unit-files
```

#### List `.timer` units

```bash
systemctl list-timers
```

> **Pro-Tip:** Use `--no-pager` to bypass default `less` output screen-trap.

---

### journalctl

`systemctl` is how you _control_ your services.
`journalctl` is how you _see what they're doing_.

`systemd` has a centralized logging service unit called `systemd-journald`. It collects logs from the kernel, the boot process, and every single `systemd` service unit, and stores them in an indexed, binary format.

Since the logs are binary (non-readable), you must use `journalctl` to filter and read them.

| Command                           | What it does                                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `journalctl -u <service_name>`    | **The lifesaver.** Shows logs _only_ for a specific service (e.g., `journalctl -u nginx`). If a service crashes, run this immediately.     |
| `journalctl -f`                   | **Follow mode.** Streams logs live as they happen in real-time, exactly like `tail -f`.                                                    |
| `journalctl -e`                   | **Jump to the end.** Opens the log pager and drops you right at the very bottom (the most recent events).                                  |
| `journalctl --since "1 hour ago"` | **Time travel.** Filters logs by time. You can use human-readable formats like `"yesterday"`, `"10 minutes ago"`, or `"2026-06-01 14:00"`. |
| `journalctl -p err`               | **Filter by priority.** Shows only log entries marked as errors (or worse), hiding all the normal informational noise.                     |

> **Pro-Tip:** You can combine these! If you want to watch the live logs for your web server because you are testing a configuration change, you would run: `journalctl -u nginx -f`

### `-b` boot flag

- `journalctl -b`: Shows logs only from the current boot.
- `journalctl -b -1`: Shows logs from the _previous_ boot (perfect for figuring out why a server suddenly restarted).
