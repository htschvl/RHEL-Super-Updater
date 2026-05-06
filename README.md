# RHEL-Super-Updater

**Version:** 3.3
**Target:** Fedora 44 (DNF 5)
**Type:** Fully non-interactive system updater and cleaner

---

## Overview

`updater` is a Bash script designed to **update, clean, and audit** a Fedora-based system in a single run.

It executes a structured pipeline covering:

* DNF package management
* Firmware updates (fwupd)
* Flatpak (system + user)
* Snap
* GNOME extensions
* System journal cleanup
* System bloat inspection (informational)

All operations are **non-interactive** (`--assumeyes` wherever applicable).

---

## Features

* Fully automated update pipeline
* Per-step status reporting (OK / WARNING / FAILED / SKIPPED)
* Timeout handling for long-running operations
* Detailed logging with colored output
* Safe redundancy (`distro-sync` + `upgrade`)
* Flatpak support (system + user separation)
* GNOME extensions update via `gext`
* Journal size/time vacuuming
* Bloat inspection (no automatic removal)

---

## Usage

```bash
sudo ./updater {shutdown|reboot|keepon}
```

### Actions

| Action   | Description                |
| -------- | -------------------------- |
| shutdown | Power off after completion |
| reboot   | Reboot after completion    |
| keepon   | Keep the system running    |

---

## Pipeline

Execution order:

1. DNF cache clean
2. Metadata rebuild (`makecache`)
3. Package synchronization:

   * `dnf distro-sync`
   * `dnf upgrade` (safety pass)
4. Orphan & unused packages:

   * `repoquery --extras`
   * `repoquery --unneeded`
   * `package-cleanup` (if available)
   * `dnf autoremove`
5. Firmware updates (`fwupd`)
6. Flatpak:

   * System update + prune
   * User update + prune
7. Snap refresh
8. GNOME extensions update (`gext`)
9. Journal cleanup (`journalctl vacuum`)
10. Bloat inspection (read-only)

---

## Requirements

### Mandatory

* Fedora / RHEL-based system
* `dnf`

### Optional (auto-detected)

| Tool            | Purpose                    |
| --------------- | -------------------------- |
| fwupdmgr        | Firmware updates           |
| flatpak         | Flatpak management         |
| snap            | Snap updates               |
| gext            | GNOME extensions CLI       |
| package-cleanup | Extra DNF inspection tools |

---

## Installation

```bash
chmod +x updater
```

Optional dependencies:

```bash
sudo dnf install fwupd flatpak snapd dnf-plugins-core
pipx install gnome-extensions-cli
```

---

## GNOME Extensions (Important)

* Requires an active GNOME session
* Must be executed via `sudo`
* Uses `gext` installed for the **non-root user**

If not available, this step **fails (not skipped)**.

---

## Timeouts

| Component | Timeout |
| --------- | ------- |
| fwupd     | 600s    |
| flatpak   | 600s    |
| snap      | 600s    |
| gext      | 300s    |

---

## Journal Cleanup

* Retention: **14 days**
* Max size: **500MB**

Commands used:

```bash
journalctl --vacuum-time=14d
journalctl --vacuum-size=500M
```

---

## Bloat Inspection

This step is **informational only**.

Includes:

* Unneeded packages
* Extra packages (not in active repos)
* Duplicate packages
* Largest installed packages
* Leaf packages
* RPMDB integrity check
* Installed kernel count

No automatic removal is performed.

---

## Exit Behavior

Each step returns:

* `0` → OK
* `2` → Skipped
* `124` → Timeout
* Other → Failure

Final summary includes:

* Completed steps
* Warnings
* Skipped steps
* Failed steps

---

## Safety Notes

* Requires `sudo`
* Assumes **yes** to all prompts
* Some operations (e.g., firmware updates) may still require a reboot
* Review failures before shutdown/reboot

---

## Example

```bash
sudo ./updater reboot
```

---

## Philosophy

* Prefer **deterministic system state** (`distro-sync`)
* Prefer **explicit visibility** over silent behavior
* Avoid destructive automation in uncertain scenarios
* Separate **cleanup** from **inspection**

---

## License

GNU General Public License v3.0

