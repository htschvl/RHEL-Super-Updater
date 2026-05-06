#!/usr/bin/env bash
# updater — Updates and trims the system (DNF, Firmware, Flatpak, Snap, GNOME)
# Version 3.3 — target: Fedora 44 with DNF 5
# Fully non-interactive: --assumeyes on every command that could prompt.

set -uo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

readonly ACTION="${1:-}"
readonly SCRIPT_VERSION="3.3"

# Timeouts (seconds). 0 = no timeout.
readonly TIMEOUT_FWUPD=600
readonly TIMEOUT_FLATPAK=600
readonly TIMEOUT_SNAP=600
readonly TIMEOUT_GEXT=300

# Journal retention
readonly JOURNAL_RETAIN_DAYS=14
readonly JOURNAL_MAX_SIZE="500M"

# How many items to show in inspection listings
readonly INSPECT_LIMIT=20

# ─── Colors and icons ────────────────────────────────────────────────────────

readonly C_RESET="\033[0m"
readonly C_BOLD="\033[1m"
readonly C_DIM="\033[2m"
readonly C_CYAN="\033[1;36m"
readonly C_GREEN="\033[1;32m"
readonly C_YELLOW="\033[1;33m"
readonly C_RED="\033[1;31m"
readonly C_MAGENTA="\033[1;35m"
readonly C_BLUE="\033[1;34m"
readonly C_WHITE="\033[1;37m"

readonly ICON_OK="✔"
readonly ICON_WARN="⚠"
readonly ICON_FAIL="✘"
readonly ICON_INFO="ℹ"
readonly ICON_ROCKET="🚀"
readonly ICON_CLOCK="⏱"
readonly ICON_ARROW="▸"

readonly ICON_CLEAN="🧹"
readonly ICON_CACHE="📥"
readonly ICON_SYNC="🔄"
readonly ICON_ORPHAN="🗑"
readonly ICON_FLATPAK="📦"
readonly ICON_SNAP="🔩"
readonly ICON_GNOME="🧩"
readonly ICON_FW="⚡"
readonly ICON_JOURNAL="📰"
readonly ICON_INSPECT="🔍"

readonly LINE_THICK="══════════════════════════════════════════════════════════════"
readonly LINE_THIN="──────────────────────────────────────────────────────────────"

# ─── Step pipeline (icon|label|function) ─────────────────────────────────────

readonly STEPS=(
  "${ICON_CLEAN}|Cleaning DNF cache|step_dnf_clean"
  "${ICON_CACHE}|Rebuilding metadata|step_dnf_makecache"
  "${ICON_SYNC}|Syncing packages (distro-sync + upgrade)|step_dnf_distrosync"
  "${ICON_ORPHAN}|Removing orphan packages (autoremove)|step_dnf_autoremove"
  "${ICON_FW}|Updating firmware (fwupd)|step_firmware"
  "${ICON_FLATPAK}|Updating and cleaning Flatpaks|step_flatpak"
  "${ICON_SNAP}|Updating Snaps|step_snap"
  "${ICON_GNOME}|Updating GNOME extensions|step_gnome_extensions"
  "${ICON_JOURNAL}|Cleaning old journal|step_journal_vacuum"
  "${ICON_INSPECT}|Bloat inspection (informational)|step_inspect_bloat"
)

readonly TOTAL_STEPS=${#STEPS[@]}

# ─── Global state ────────────────────────────────────────────────────────────

STEPS_OK=0
STEPS_SKIPPED=0
STEPS_WARNED=0
STEPS_FAILED=0
START_TIME=0
CURRENT_STEP=0
declare -a STEP_TIMINGS=()  # "label|status|elapsed_seconds"

# ─── Trap ────────────────────────────────────────────────────────────────────

cleanup_on_signal() {
  printf "\n"
  printf "  ${C_RED}${ICON_FAIL}${C_RESET}  Script interrupted by user or signal.\n" >&2
  printf "\033]0;\007"
  exit 130
}

trap cleanup_on_signal INT TERM

# ─── Logging ─────────────────────────────────────────────────────────────────

log_info()    { printf "  ${C_CYAN}${ICON_INFO}${C_RESET}  %s\n" "$1"; }
log_success() { printf "  ${C_GREEN}${ICON_OK}${C_RESET}  %s\n" "$1"; }
log_warn()    { printf "  ${C_YELLOW}${ICON_WARN}${C_RESET}  %s\n" "$1"; }
log_error()   { printf "  ${C_RED}${ICON_FAIL}${C_RESET}  %s\n" "$1" >&2; }
log_skip()    { printf "  ${C_DIM}─  %s${C_RESET}\n" "$1"; }
log_dim()     { printf "  ${C_DIM}%s${C_RESET}\n" "$1"; }

log_substep() { printf "    ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}%s${C_RESET}\n" "$1"; }

log_step_header() {
  local icon="$1" label="$2" step="$3"
  printf "\033]0;updater — [%d/%d] %s\007" "$step" "$TOTAL_STEPS" "$label"
  printf "\n${C_MAGENTA}${LINE_THIN}${C_RESET}\n"
  printf "  %s  ${C_WHITE}[%d/%d]${C_RESET}  ${C_BOLD}%s${C_RESET}\n" \
    "$icon" "$step" "$TOTAL_STEPS" "$label"
  printf "${C_MAGENTA}${LINE_THIN}${C_RESET}\n\n"
}

# ─── Command execution ───────────────────────────────────────────────────────

# run_cmd <timeout|0> <command> [args...]
run_cmd() {
  local timeout_val="$1"; shift
  local exit_code=0

  if [[ "$timeout_val" -gt 0 ]]; then
    timeout "$timeout_val" "$@" || exit_code=$?
  else
    "$@" || exit_code=$?
  fi

  return "$exit_code"
}

# run_subcmd <description> <timeout|0> <command> [args...]
# Unlike run_cmd: prints OK/FAILED for EACH invocation, so steps with
# multiple commands report each one individually.
run_subcmd() {
  local desc="$1" timeout_val="$2"; shift 2
  local rc=0

  log_substep "$desc"
  printf "\n"
  run_cmd "$timeout_val" "$@" || rc=$?
  printf "\n"

  if [[ "$rc" -eq 0 ]]; then
    log_success "${desc} — OK"
  elif [[ "$rc" -eq 124 ]]; then
    log_warn "${desc} — TIMEOUT (${timeout_val}s)"
  else
    log_error "${desc} — FAILED (rc=${rc})"
  fi
  printf "\n"

  return "$rc"
}

# Records step result + elapsed time
record_step() {
  local label="$1" status="$2" elapsed="$3"
  STEP_TIMINGS+=("${label}|${status}|${elapsed}")

  case "$status" in
    ok)   (( STEPS_OK++ )) ;;
    skip) (( STEPS_SKIPPED++ )) ;;
    warn) (( STEPS_WARNED++ )) ;;
    fail) (( STEPS_FAILED++ )) ;;
  esac
}

# ─── Help ────────────────────────────────────────────────────────────────────

show_help() {
  printf "\n${C_WHITE}${LINE_THICK}${C_RESET}\n"
  printf "\n  ${C_BOLD}${ICON_ROCKET}  updater${C_RESET} v${SCRIPT_VERSION} — System updater and cleaner\n"
  printf "\n${C_CYAN}  Usage:${C_RESET}\n"
  printf "    sudo %s ${C_WHITE}{shutdown|reboot|keepon|--help}${C_RESET}\n\n" "$(basename "$0")"
  printf "${C_CYAN}  Pipeline:${C_RESET}\n"
  printf "    DNF (clean → makecache → distro-sync + upgrade → autoremove)\n"
  printf "    Firmware (fwupd) → Flatpak (system + user, prune) → Snap → GNOME ext.\n"
  printf "    Journal vacuum → Bloat inspection\n\n"
  printf "${C_CYAN}  Actions:${C_RESET}\n"
  printf "    ${C_WHITE}shutdown${C_RESET}   Power off after updates\n"
  printf "    ${C_WHITE}reboot${C_RESET}     Reboot after updates\n"
  printf "    ${C_WHITE}keepon${C_RESET}     Keep running\n"
  printf "    ${C_WHITE}--help${C_RESET}     Show this help\n\n"
  printf "${C_CYAN}  Note:${C_RESET}  Fully non-interactive — assumes 'yes' to every prompt.\n\n"
  printf "${C_WHITE}${LINE_THICK}${C_RESET}\n\n"
  exit 0
}

# ─── Validation ──────────────────────────────────────────────────────────────

validate_action() {
  case "$ACTION" in
    shutdown|reboot|keepon)
      if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run with sudo."
        printf "  ${C_DIM}Try: sudo %s %s${C_RESET}\n\n" "$(basename "$0")" "$ACTION"
        exit 1
      fi
      ;;
    --help|-h) show_help ;;
    "")
      log_error "No action provided."
      printf "\n"
      show_help
      ;;
    *)
      log_error "Unknown action: '$ACTION'"
      printf "\n"
      show_help
      ;;
  esac
}

validate_dependencies() {
  if ! command -v dnf &>/dev/null; then
    log_error "dnf not found. This script requires Fedora/RHEL/derivative."
    exit 1
  fi
}

# ─── Header with system info and sources ─────────────────────────────────────

show_header() {
  local distro kernel hostname uptime_str dnf_ver repo_count

  distro=$(. /etc/os-release && echo "$PRETTY_NAME" 2>/dev/null || echo "Linux")
  kernel=$(uname -r)
  hostname=$(hostnamectl --static 2>/dev/null || hostname)
  uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")
  dnf_ver=$(dnf --version 2>/dev/null | head -1 || echo "?")
  repo_count=$(dnf repolist --enabled 2>/dev/null | tail -n +2 | wc -l)

  printf "\n${C_WHITE}${LINE_THICK}${C_RESET}\n"
  printf "  ${ICON_ROCKET}  ${C_BOLD}System Updater${C_RESET} ${C_DIM}v${SCRIPT_VERSION}${C_RESET}\n"
  printf "${C_WHITE}${LINE_THICK}${C_RESET}\n"
  printf "  ${C_DIM}Distro      :${C_RESET}  %s\n" "$distro"
  printf "  ${C_DIM}Kernel      :${C_RESET}  %s\n" "$kernel"
  printf "  ${C_DIM}Hostname    :${C_RESET}  %s\n" "$hostname"
  printf "  ${C_DIM}Uptime      :${C_RESET}  %s\n" "$uptime_str"
  printf "  ${C_DIM}DNF         :${C_RESET}  %s\n" "$dnf_ver"
  printf "  ${C_DIM}DNF repos   :${C_RESET}  %d active\n" "$repo_count"
  printf "  ${C_DIM}Final action:${C_RESET}  %s\n" "$ACTION"
  printf "${C_WHITE}${LINE_THICK}${C_RESET}\n"

  # List active repos so it's explicit which sources will be queried
  if [[ "$repo_count" -gt 0 ]]; then
    printf "  ${C_DIM}Enabled DNF sources:${C_RESET}\n"
    dnf repolist --enabled 2>/dev/null | tail -n +2 | awk '{print $1}' | sed 's/^/      /'
    printf "${C_WHITE}${LINE_THICK}${C_RESET}\n"
  fi
}

# ─── Steps: DNF ──────────────────────────────────────────────────────────────

step_dnf_clean() {
  run_cmd 0 dnf clean all
}

step_dnf_makecache() {
  run_cmd 0 dnf makecache
}

step_dnf_distrosync() {
  # Intentional redundancy: distro-sync + upgrade.
  # distro-sync aligns with active repos (including downgrades); upgrade picks
  # up anything distro-sync left behind because it wasn't reconciling.
  local rc=0
  run_subcmd "dnf distro-sync --refresh --best" 0 \
    dnf distro-sync --refresh --best --assumeyes || rc=$?
  run_subcmd "dnf upgrade --refresh --best (safety pass)" 0 \
    dnf upgrade --refresh --best --assumeyes || rc=$?
  return "$rc"
}

step_dnf_autoremove() {
  # Runs several informational listings + final autoremove.
  # Each subcommand reports success/failure individually.
  local rc=0

  run_subcmd "dnf repoquery --extras (installed but not in any active repo)" 0 \
    dnf repoquery --extras || rc=$?

  run_subcmd "dnf repoquery --unneeded (autoremove candidates)" 0 \
    dnf repoquery --unneeded || rc=$?

  if command -v package-cleanup &>/dev/null; then
    run_subcmd "package-cleanup --orphans" 0 \
      package-cleanup --orphans || rc=$?
    run_subcmd "package-cleanup --leaves" 0 \
      package-cleanup --leaves || rc=$?
  else
    log_warn "package-cleanup not available — skipping."
    log_dim "    To install:  sudo dnf install dnf-plugins-core"
    printf "\n"
  fi

  run_subcmd "dnf autoremove (actual removal)" 0 \
    dnf autoremove --assumeyes || rc=$?

  return "$rc"
}

# ─── Step: Firmware ──────────────────────────────────────────────────────────

step_firmware() {
  if ! command -v fwupdmgr &>/dev/null; then
    log_warn "fwupd is not installed — skipping."
    log_dim "To install:  sudo dnf install fwupd"
    return 2
  fi

  local rc=0

  log_substep "fwupdmgr refresh (LVFS metadata)"
  printf "\n"
  run_cmd "$TIMEOUT_FWUPD" fwupdmgr refresh --force \
    && log_success "LVFS metadata refreshed" \
    || log_warn "Metadata refresh failed (continuing)"
  printf "\n"

  # `get-updates` returns 2 when there's nothing — not an error
  log_substep "fwupdmgr get-updates"
  printf "\n"
  local fw_exit=0
  fwupdmgr get-updates || fw_exit=$?
  printf "\n"

  if [[ "$fw_exit" -eq 2 ]]; then
    log_success "No firmware to update."
    return 0
  fi

  run_subcmd "fwupdmgr update (apply firmware)" "$TIMEOUT_FWUPD" \
    fwupdmgr update --assume-yes --no-reboot-check || rc=$?

  return "$rc"
}

# ─── Step: Flatpak (system + user) ───────────────────────────────────────────

step_flatpak() {
  if ! command -v flatpak &>/dev/null; then
    log_warn "Flatpak is not installed — skipping."
    return 2
  fi

  local rc=0

  # 1. System-wide (root): /var/lib/flatpak
  run_subcmd "flatpak update --system (system-wide install)" "$TIMEOUT_FLATPAK" \
    flatpak update --assumeyes --noninteractive --system || rc=$?

  run_subcmd "flatpak uninstall --unused --system (prune system)" "$TIMEOUT_FLATPAK" \
    flatpak uninstall --unused --assumeyes --noninteractive --system || rc=$?

  # 2. Per-user (from SUDO_USER, not root): ~/.local/share/flatpak
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    run_subcmd "flatpak update --user (per-user install for ${SUDO_USER})" "$TIMEOUT_FLATPAK" \
      runuser -l "$SUDO_USER" -c 'flatpak update --assumeyes --noninteractive --user' || rc=$?

    run_subcmd "flatpak uninstall --unused --user (prune user)" "$TIMEOUT_FLATPAK" \
      runuser -l "$SUDO_USER" -c 'flatpak uninstall --unused --assumeyes --noninteractive --user' || rc=$?
  else
    log_warn "SUDO_USER not set or is root — skipping per-user update."
    printf "\n"
  fi

  # Final stats
  local sys_apps user_apps
  sys_apps=$(flatpak list --app --system 2>/dev/null | wc -l)
  user_apps=0
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    user_apps=$(runuser -l "$SUDO_USER" -c 'flatpak list --app --user 2>/dev/null | wc -l' || echo 0)
  fi
  log_dim "Flatpak apps: ${sys_apps} system / ${user_apps} user"

  return "$rc"
}

# ─── Step: Snap ──────────────────────────────────────────────────────────────

step_snap() {
  if ! command -v snap &>/dev/null; then
    log_warn "Snap is not installed — skipping."
    return 2
  fi

  run_cmd "$TIMEOUT_SNAP" snap refresh
}

# ─── Step: GNOME extensions (ESSENTIAL — does not silently skip) ─────────────

step_gnome_extensions() {
  if [[ -z "${SUDO_USER:-}" ]]; then
    log_error "SUDO_USER is not set. Can't update user extensions."
    log_error "GNOME extension updates are ESSENTIAL — this step is FAILING, not skipping."
    log_dim "Run the script via 'sudo updater ...' from an active GNOME session."
    return 1
  fi

  local uid
  uid=$(id -u "$SUDO_USER")

  # Login shell to pick up ~/.local/bin (where pipx installs gext)
  if ! runuser -l "$SUDO_USER" -c 'command -v gext' &>/dev/null; then
    log_error "gext (gnome-extensions-cli) is not installed for ${SUDO_USER}."
    log_error "GNOME extension updates are ESSENTIAL — this step is FAILING, not skipping."
    printf "\n"
    log_dim "To install (as the user, NOT as root):"
    log_dim "    pipx install gnome-extensions-cli"
    log_dim "  or"
    log_dim "    pip install --user gnome-extensions-cli"
    printf "\n"
    return 1
  fi

  # Show current state before updating — transparency
  log_info "Extensions installed for ${SUDO_USER}:"
  runuser -l "$SUDO_USER" -c "
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus
    export XDG_RUNTIME_DIR=/run/user/${uid}
    gext list 2>/dev/null
  " | sed 's/^/      /' || log_warn "Could not list extensions (active GNOME session?)"
  printf "\n"

  log_info "Updating..."
  local ext_exit=0
  timeout "$TIMEOUT_GEXT" runuser -l "$SUDO_USER" -c "
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus
    export XDG_RUNTIME_DIR=/run/user/${uid}
    gext update
  " || ext_exit=$?

  if [[ "$ext_exit" -eq 124 ]]; then
    log_error "Timeout (${TIMEOUT_GEXT}s) updating extensions."
    return 124
  elif [[ "$ext_exit" -ne 0 ]]; then
    log_error "gext update returned code $ext_exit."
    log_dim "Check that there's an active GNOME session and that extensions are compatible with the Shell version."
    return "$ext_exit"
  fi

  return 0
}

# ─── Step: Journal vacuum ────────────────────────────────────────────────────

step_journal_vacuum() {
  if ! command -v journalctl &>/dev/null; then
    log_warn "journalctl not available — skipping."
    return 2
  fi

  local size_before size_after
  size_before=$(journalctl --disk-usage 2>/dev/null | grep -oP '\S+[A-Z]+' | head -1 || echo "?")

  log_info "Size before: ${size_before}"
  log_info "Capping at ${JOURNAL_RETAIN_DAYS} days AND ${JOURNAL_MAX_SIZE}..."

  run_cmd 0 journalctl --vacuum-time="${JOURNAL_RETAIN_DAYS}d"
  run_cmd 0 journalctl --vacuum-size="${JOURNAL_MAX_SIZE}"

  size_after=$(journalctl --disk-usage 2>/dev/null | grep -oP '\S+[A-Z]+' | head -1 || echo "?")
  log_dim "Size after: ${size_after}"
}

# ─── Step: Bloat inspection (informational, removes nothing) ─────────────────

step_inspect_bloat() {
  printf "\n"
  log_info "This step is ${C_BOLD}informational${C_RESET}. Nothing will be removed automatically."
  log_info "Review the lists and manually remove what you recognize as useless."
  printf "\n"

  # 1. Unneeded packages
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Unneeded packages${C_RESET} ${C_DIM}(dnf repoquery --unneeded)${C_RESET}\n"
  local unneeded
  unneeded=$(dnf repoquery --unneeded -q 2>/dev/null | head -n "$INSPECT_LIMIT")
  if [[ -z "$unneeded" ]]; then
    log_dim "  None. ✨"
  else
    echo "$unneeded" | sed 's/^/      /'
    local total
    total=$(dnf repoquery --unneeded -q 2>/dev/null | wc -l)
    [[ "$total" -gt "$INSPECT_LIMIT" ]] && log_dim "  ... (${total} total)"
    log_dim "  To remove: sudo dnf remove <name>"
  fi
  printf "\n"

  # 2. "Extra" packages — installed but not in any enabled repo
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Extra packages${C_RESET} ${C_DIM}(dnf repoquery --extras — not in any active repo)${C_RESET}\n"
  local extras
  extras=$(dnf repoquery --extras -q 2>/dev/null | head -n "$INSPECT_LIMIT")
  if [[ -z "$extras" ]]; then
    log_dim "  None. ✨"
  else
    echo "$extras" | sed 's/^/      /'
    local total
    total=$(dnf repoquery --extras -q 2>/dev/null | wc -l)
    [[ "$total" -gt "$INSPECT_LIMIT" ]] && log_dim "  ... (${total} total)"
    log_warn "  Caveat: may include packages from repos you've temporarily disabled."
  fi
  printf "\n"

  # 3. Duplicate packages (DNF 5 supports this natively)
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Duplicate packages${C_RESET} ${C_DIM}(dnf repoquery --duplicates — multiple versions installed)${C_RESET}\n"
  local duplicates
  duplicates=$(dnf repoquery --duplicates -q 2>/dev/null | head -n "$INSPECT_LIMIT")
  if [[ -z "$duplicates" ]]; then
    log_dim "  None. ✨"
  else
    echo "$duplicates" | sed 's/^/      /'
    log_dim "  To clean: sudo dnf remove --duplicates"
  fi
  printf "\n"

  # 4. Top-N user-installed packages by size — raw list from DNF 5
  # Note: in DNF 5, --userinstalled returns packages with reason "User" AND "unknown"
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Top ${INSPECT_LIMIT} user-installed packages by size${C_RESET} ${C_DIM}(raw list, includes 'unknown reason' on DNF 5)${C_RESET}\n"
  local user_pkgs
  user_pkgs=$(dnf repoquery --userinstalled --queryformat '%{size}\t%{name}\n' -q 2>/dev/null \
    | sort -rn \
    | head -n "$INSPECT_LIMIT" \
    | awk '{
        size=$1; name=$2;
        if (size >= 1073741824) printf "      %7.1f GB  %s\n", size/1073741824, name;
        else if (size >= 1048576) printf "      %7.1f MB  %s\n", size/1048576, name;
        else printf "      %7.1f KB  %s\n", size/1024, name;
      }')
  if [[ -z "$user_pkgs" ]]; then
    log_dim "  (could not list)"
  else
    echo "$user_pkgs"
  fi
  printf "\n"

  # 5. Filtered to only reason=User explicit (workaround for the DNF 5 gotcha)
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Top ${INSPECT_LIMIT} with explicit reason='User'${C_RESET} ${C_DIM}(filtered, more accurate)${C_RESET}\n"
  local user_pkgs_filtered
  user_pkgs_filtered=$(dnf repoquery --userinstalled --queryformat '%{name}|%{reason}|%{size}\n' -q 2>/dev/null \
    | awk -F'|' '$2 == "User" { print $3 "\t" $1 }' \
    | sort -rn \
    | head -n "$INSPECT_LIMIT" \
    | awk '{
        size=$1; name=$2;
        if (size >= 1073741824) printf "      %7.1f GB  %s\n", size/1073741824, name;
        else if (size >= 1048576) printf "      %7.1f MB  %s\n", size/1048576, name;
        else printf "      %7.1f KB  %s\n", size/1024, name;
      }')
  if [[ -z "$user_pkgs_filtered" ]]; then
    log_dim "  (empty — on systems upgraded from F40, this is expected: reasons marked as 'unknown')"
  else
    echo "$user_pkgs_filtered"
  fi
  printf "\n"

  # 6. Bonus: package-cleanup --leaves if available
  if command -v package-cleanup &>/dev/null; then
    printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Leaf packages${C_RESET} ${C_DIM}(package-cleanup --leaves — first ${INSPECT_LIMIT})${C_RESET}\n"
    package-cleanup --leaves --quiet 2>/dev/null | head -n "$INSPECT_LIMIT" | sed 's/^/      /'
    printf "\n"
  fi

  # 7. RPMDB integrity (read-only, modifies nothing)
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}RPMDB integrity${C_RESET} ${C_DIM}(dnf check)${C_RESET}\n"
  local check_output check_exit=0
  check_output=$(dnf check 2>&1) || check_exit=$?
  if [[ "$check_exit" -eq 0 ]]; then
    log_dim "  RPMDB intact. ✨"
  else
    echo "$check_output" | head -n 30 | sed 's/^/      /'
    log_warn "  RPMDB issues detected (rc=${check_exit}). Review manually."
  fi
  printf "\n"

  # 8. Old kernels
  local kernel_count
  kernel_count=$(dnf repoquery --installed kernel-core -q 2>/dev/null | wc -l)
  printf "  ${C_BLUE}${ICON_ARROW}${C_RESET}  ${C_BOLD}Installed kernels:${C_RESET} %d ${C_DIM}(installonly_limit in /etc/dnf/dnf.conf)${C_RESET}\n" "$kernel_count"
  printf "\n"

  return 0
}

# ─── Main execution loop ─────────────────────────────────────────────────────

run_pipeline() {
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r icon label fn <<< "$entry"
    (( CURRENT_STEP++ ))

    log_step_header "$icon" "$label" "$CURRENT_STEP"

    local step_start step_end elapsed exit_code=0
    step_start=$(date +%s)

    "$fn" || exit_code=$?

    step_end=$(date +%s)
    elapsed=$(( step_end - step_start ))

    case "$exit_code" in
      0)
        printf "\n  ${C_GREEN}${ICON_OK}${C_RESET}  Done ${C_DIM}(${elapsed}s)${C_RESET}\n"
        record_step "$label" ok "$elapsed"
        ;;
      2)
        printf "  ${C_DIM}─  Skipped (${elapsed}s)${C_RESET}\n"
        record_step "$label" skip "$elapsed"
        ;;
      124)
        printf "\n  ${C_YELLOW}${ICON_WARN}${C_RESET}  Timeout ${C_DIM}(${elapsed}s)${C_RESET}\n"
        record_step "$label" warn "$elapsed"
        ;;
      *)
        printf "\n  ${C_RED}${ICON_FAIL}${C_RESET}  Failed with code $exit_code ${C_DIM}(${elapsed}s)${C_RESET}\n" >&2
        record_step "$label" fail "$elapsed"
        ;;
    esac
  done
}

# ─── Summary ─────────────────────────────────────────────────────────────────

show_summary() {
  local C_SUMMARY
  if   [[ "$STEPS_FAILED"  -gt 0 ]]; then C_SUMMARY="$C_RED"
  elif [[ "$STEPS_WARNED"  -gt 0 ]]; then C_SUMMARY="$C_YELLOW"
  elif [[ "$STEPS_SKIPPED" -gt 0 ]]; then C_SUMMARY="$C_CYAN"
  else                                     C_SUMMARY="$C_GREEN"
  fi

  local total_elapsed=$(( $(date +%s) - START_TIME ))
  local mins=$(( total_elapsed / 60 ))
  local secs=$(( total_elapsed % 60 ))

  printf "\n${C_SUMMARY}${LINE_THICK}${C_RESET}\n"
  printf "  ${C_BOLD}Summary${C_RESET}  ${C_DIM}${ICON_CLOCK} %dm%02ds total${C_RESET}\n" "$mins" "$secs"
  printf "${C_SUMMARY}${LINE_THICK}${C_RESET}\n\n"

  for timing in "${STEP_TIMINGS[@]}"; do
    IFS='|' read -r label status elapsed <<< "$timing"
    case "$status" in
      ok)   printf "  ${C_GREEN}${ICON_OK}${C_RESET}  %-50s  ${C_DIM}%4ds${C_RESET}\n" "$label" "$elapsed" ;;
      skip) printf "  ${C_DIM}─  %-50s  %4ds${C_RESET}\n" "$label" "$elapsed" ;;
      warn) printf "  ${C_YELLOW}${ICON_WARN}${C_RESET}  %-50s  ${C_DIM}%4ds${C_RESET}\n" "$label" "$elapsed" ;;
      fail) printf "  ${C_RED}${ICON_FAIL}${C_RESET}  %-50s  ${C_DIM}%4ds${C_RESET}\n" "$label" "$elapsed" ;;
    esac
  done

  printf "\n${C_SUMMARY}${LINE_THIN}${C_RESET}\n"
  printf "  ${C_GREEN}${ICON_OK}${C_RESET} %d done   " "$STEPS_OK"
  printf "${C_YELLOW}${ICON_WARN}${C_RESET} %d warnings   " "$STEPS_WARNED"
  printf "${C_DIM}─${C_RESET} %d skipped   " "$STEPS_SKIPPED"
  printf "${C_RED}${ICON_FAIL}${C_RESET} %d failed\n" "$STEPS_FAILED"
  printf "${C_SUMMARY}${LINE_THICK}${C_RESET}\n\n"
}

# ─── Final action ────────────────────────────────────────────────────────────

perform_action() {
  printf "\033]0;\007"

  case "$ACTION" in
    reboot)
      log_info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
      sleep 5
      systemctl reboot -i
      ;;
    shutdown)
      log_info "Shutting down in 5 seconds... (Ctrl+C to cancel)"
      sleep 5
      systemctl poweroff -i
      ;;
    keepon)
      log_info "System will stay on."
      ;;
  esac
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  validate_action
  validate_dependencies

  START_TIME=$(date +%s)

  show_header
  run_pipeline
  show_summary

  if [[ "$STEPS_FAILED" -gt 0 ]]; then
    log_warn "There were failures. Review recommended before ${ACTION}."
  fi

  perform_action
}

main "$@"
