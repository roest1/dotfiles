# Systemd

Way of managing Linux systems.

### Units

- Everything is a "Unit"

Instead of writing messy bash scripts to start services, `systemd` uses standardized configuration files called Unit Files.

### Types of Units

- `.service` - _tells the system what to do_
- `.timer` - _tells the system when to do it_
- `.path` - _triggers the system on filesystem activity_
- `.mount`

## systemctl

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

## journalctl

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
