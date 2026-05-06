# 🚀 RHEL Super Updater

> A single-command, fully non-interactive updater and cleaner for **Fedora / RHEL** systems running **DNF 5**.

It runs a **10-step pipeline** that updates everything (packages, firmware, Flatpaks, Snaps, GNOME extensions), trims accumulated bloat (duplicates, old kernels, broken RPMDB, dangling dependencies), vacuums the systemd journal, and optionally powers off or reboots the machine when done — all from one entrypoint.

The script is opinionated about safety: it **never auto-removes user-installed packages**, respects `installonly_limit` for kernels, and treats GNOME extension updates as **essential** (it fails loudly instead of silently skipping them).

---

## ✨ Highlights

- ⚡ **Zero prompts.** `--assumeyes` / `--noninteractive` on every command that could ask a question.
- 🎨 **Readable output.** Color-coded steps, Unicode icons, per-step timing, terminal title updates, and a final summary table.
- ⏱ **Hard timeouts** on every long-running step (firmware, Flatpak, Snap, GNOME extensions) — nothing can hang forever.
- 🛡 **Conservative cleanup.** Leaves with `reason="User"`, `"Group"`, `"Weak"`, or `"unknown"` are **never** auto-removed. Only true dependency leaves go.
- 🧠 **Distinguishes failure from skip.** Missing tool → `skip`. Tool present but broken → `fail`. Timeout → `warn`. Each shows up differently in the summary.
- 🔁 **Distro-sync + upgrade combo.** Catches everything `distro-sync` alone would miss after repo realignment.
- 🌐 **Forces English output** (`LC_ALL=C.UTF-8`) so error messages are greppable and consistent across locales.
- 📦 **Multi-source.** DNF + fwupd (LVFS) + Flatpak (system **and** per-user) + Snap + GNOME Shell extensions, all in one pass.

---

## 📋 Pipeline

The script runs these 10 steps in order. Order matters: install/update first, then trim, then journal vacuum last (so the vacuum captures logs from the run itself).

| #  | Icon | Step                       | What it does                                                                 |
|----|------|----------------------------|------------------------------------------------------------------------------|
| 1  | 🧹   | Cleaning DNF cache         | `dnf clean all`                                                              |
| 2  | 📥   | Rebuilding metadata        | `dnf makecache`                                                              |
| 3  | 🔄   | Syncing packages           | `dnf distro-sync --refresh --best` then `dnf upgrade --refresh --best`       |
| 4  | 🗑   | Removing orphans           | `package-cleanup --orphans` (if available) + `dnf autoremove`                |
| 5  | ⚡   | Updating firmware          | `fwupdmgr refresh` → `get-updates` → `update --no-reboot-check`              |
| 6  | 📦   | Updating Flatpaks          | system + per-user update + prune unused                                       |
| 7  | 🔩   | Updating Snaps             | `snap refresh`                                                                |
| 8  | 🧩   | Updating GNOME extensions  | `gext update` as the invoking user (via `runuser -l $SUDO_USER`)              |
| 9  | 🔍   | Removing bloat             | duplicates, old kernels, RPMDB, dependency leaves, final autoremove          |
| 10 | 📰   | Cleaning old journal       | caps at 14 days **and** 500 MB                                                |

---

## 🚀 Usage

```bash
sudo ./updater.sh {shutdown|reboot|keepon|--help}
```

| Action     | Behavior                                       |
|------------|------------------------------------------------|
| `shutdown` | Power off after the pipeline completes         |
| `reboot`   | Reboot after the pipeline completes            |
| `keepon`   | Stay on (just run the pipeline and exit)       |
| `--help`   | Show built-in help and exit                    |

Both `shutdown` and `reboot` give a **5-second cancel window** (`Ctrl+C` to abort) before pulling the trigger.

> ⚠️ The action argument is **required**. Running the script with no argument prints help and exits with an error.

### Example

```bash
sudo ./updater.sh keepon     # weekday maintenance
sudo ./updater.sh reboot     # after kernel/firmware updates
sudo ./updater.sh shutdown   # end-of-day update + power off
```

---

## 📦 Requirements

### Mandatory

- **OS**: Fedora, RHEL, or any DNF 5–based derivative (Rocky, Alma, etc.)
- **Privileges**: root (`sudo`)
- **Tools**: `dnf`, `bash`, `timeout`, `awk`, `sed`, `grep`, `wc`, `xargs`

The script **hard-fails** if `dnf` is missing.

### Optional (gracefully skipped if absent)

| Tool                  | Used by                          | Install                                  |
|-----------------------|----------------------------------|------------------------------------------|
| `fwupdmgr`            | Firmware step                    | `sudo dnf install fwupd`                 |
| `flatpak`             | Flatpak step                     | `sudo dnf install flatpak`               |
| `snap`                | Snap step                        | `sudo dnf install snapd`                 |
| `package-cleanup`     | Orphans + leaves detection       | `sudo dnf install dnf-utils`             |
| `journalctl`          | Journal vacuum                   | ships with systemd                        |

### Optional but treated as essential

| Tool                  | Why                                                                |
|-----------------------|---------------------------------------------------------------------|
| `gext` (gnome-extensions-cli) | GNOME extension step — **fails loudly** if missing, does not skip. |

Install `gext` as the **regular user**, not root:

```bash
pipx install gnome-extensions-cli
# or
pip install --user gnome-extensions-cli
```

---

## ⚙️ Configuration

All knobs live as `readonly` constants near the top of the script.

| Variable                | Default | Meaning                                           |
|-------------------------|---------|---------------------------------------------------|
| `TIMEOUT_FWUPD`         | `600`   | Max seconds for any single fwupd command          |
| `TIMEOUT_FLATPAK`       | `600`   | Max seconds for any single Flatpak command        |
| `TIMEOUT_SNAP`          | `600`   | Max seconds for `snap refresh`                    |
| `TIMEOUT_GEXT`          | `300`   | Max seconds for `gext update`                     |
| `JOURNAL_RETAIN_DAYS`   | `14`    | Journal entries older than this are vacuumed      |
| `JOURNAL_MAX_SIZE`      | `500M`  | Hard size cap on the journal                      |

`0` disables the timeout for that step.

---

## 🔍 What "Removing bloat" actually does

This is the most opinionated step. It only acts when something is actually present, and it draws a hard line between **safe** and **unsafe** removals.

### Handled

1. **Duplicates** → `dnf remove --duplicates --assumeyes`
2. **Old kernels** → `dnf remove --oldinstallonly --assumeyes` (reads `installonly_limit` from `/etc/dnf/dnf.conf`, defaults to 3)
3. **RPMDB integrity** → if `dnf check` returns non-zero, runs `rpm --rebuilddb`
4. **Dependency leaves** → only packages where `package-cleanup --leaves` reports them **and** `dnf repoquery` confirms `reason=Dependency`
5. **Final autoremove pass** → catches anything orphaned by steps 1–4

### Deliberately NOT touched

- **Extras** (`dnf repoquery --extras`) — would delete manually-installed RPMs
- **User-installed leaves** — same risk
- **Packages with `reason="unknown"`** — legacy from pre-DNF5 systems, ambiguous origin
- **Leaves with reason `User`, `Group`, or `Weak`** — explicitly chosen by you

If everything is clean, you get a satisfying `No bloat found. ✨`.

---

## 📊 Output & status model

Every step ends with one of four statuses, recorded for the final summary:

| Status       | Exit code | Meaning                                         |
|--------------|-----------|-------------------------------------------------|
| ✔ **OK**     | `0`       | Step completed successfully                     |
| ─ **Skip**   | `2`       | Tool missing or nothing to do                   |
| ⚠ **Warn**   | `124`     | Step hit its timeout                            |
| ✘ **Fail**   | other     | Step ran but returned a non-zero error code     |

The summary at the end shows:

- A per-step table with elapsed seconds
- Total wall-clock time (`Xm YYs`)
- Aggregate counts: ✔ done · ⚠ warnings · ─ skipped · ✘ failed
- The summary banner takes the worst color: 🟥 if anything failed, 🟨 if anything warned, 🟦 if anything skipped, 🟩 otherwise.

The terminal title is also kept live (`RHEL Super Updater — [N/10] <step name>`) and reset at the end.

---

## 🛟 Safety notes

- **`set -uo pipefail`** is set, but **not `-e`** — the pipeline is designed to keep going on per-step failures so one broken repo doesn't abort firmware updates.
- **`SIGINT` / `SIGTERM`** are trapped and exit with code `130`, restoring the terminal title.
- **GNOME extensions step requires `SUDO_USER`** — it refuses to run from a true-root login because there's no user session to talk to over D-Bus.
- **Per-user Flatpak updates** are run as the invoking user via `runuser -l "$SUDO_USER"`, never as root.
- **Firmware updates** use `--no-reboot-check`, so a pending firmware update won't block the rest of the pipeline; reboot it yourself if needed (`./updater.sh reboot`).

---

## 🧭 Exit codes

| Code  | Meaning                                                |
|-------|--------------------------------------------------------|
| `0`   | All steps OK                                           |
| `1`   | Validation failure (no sudo, missing dnf, bad arg)     |
| `130` | Interrupted by `SIGINT` / `SIGTERM`                    |

Per-step failures **do not** propagate to the script's overall exit code — they are summarized instead. If you want a hard fail-on-error build, wrap the call yourself and inspect the summary output.

---

## 📁 File layout

The script is a single self-contained Bash file. No external config, no state files, no cache. Drop it anywhere on `$PATH`:

```bash
sudo install -m 0755 updater.sh /usr/local/sbin/updater
sudo updater keepon
```

---

## 📝 License

Add your preferred license here.
