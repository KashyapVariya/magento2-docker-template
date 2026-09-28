#!/usr/bin/env bash
# Shared helpers sourced by every script in bin/. Source with:
#   . "$(dirname "$0")/../lib/common.sh"
#
# Also cd's to the project root (the folder containing bin/ and lib/), so every
# bin/ script can use plain relative paths (.env, docker compose, bin/other-command)
# no matter what directory it was invoked from.

set -euo pipefail

_common_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_common_sh_dir/.." && pwd)"
cd "$PROJECT_ROOT"

# shellcheck source=./versions.sh
. "$_common_sh_dir/versions.sh"

ENV_FILE=.env

die() { echo "Error: $*" >&2; exit 1; }

# Extracts the bare hostname from BASE_URL (strips scheme, port, and path) --
# e.g. "http://store1.test:8080/" -> "store1.test". This is the single source of
# truth for what domain a shop answers to: bin/certs reads it to decide what to
# put in the HTTPS cert's SAN list, and bin/init prints the /etc/hosts line for it.
base_url_host() {
    local host="${BASE_URL#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    printf '%s\n' "$host"
}

# True if /etc/hosts already maps $1 to a loopback address (127.*/::1) -- i.e. the
# reminder below has already been acted on and doesn't need repeating. Plain
# grep/awk on /etc/hosts rather than getent/dscacheutil, since those differ (or
# don't exist) across Linux/macOS, whereas /etc/hosts's format is the same
# everywhere and it's the exact file the reminder tells you to edit.
host_already_mapped() {
    local host="$1"
    [ -r /etc/hosts ] || return 1
    awk -v h="$host" '
        $1 ~ /^#/ { next }
        { for (i = 2; i <= NF; i++) if ($i == h) { print $1; exit } }
    ' /etc/hosts | grep -qE '^(127\.|::1$)'
}

# Makes sure BASE_URL's custom domain actually resolves to this machine: a no-op
# for localhost/already-mapped domains, otherwise tries to append the entry to
# /etc/hosts itself via `sudo tee` -- sudo reads the password straight from the
# controlling terminal (not stdin), so this works from an interactive shell same
# as typing the command yourself. Falls back to just printing the line to add
# manually when there's no terminal to prompt on (piped/CI/non-interactive), sudo
# isn't installed, or the append fails/is declined -- this must never be what
# turns a `set -euo pipefail` script fatal, since not being able to touch a
# system file isn't this template's failure to recover from.
#
# Called right after the domain is chosen/changed (bin/init, bin/certs) and
# from print_urls, so on every `init`/`start`/`restart` it's re-checked (and, on
# a real terminal, self-heals) for as long as the entry is actually missing --
# a one-time prompt buried under minutes of composer/docker output is too easy
# to miss or decline by accident and then forget about.
ensure_hosts_entry() {
    local host
    host="$(base_url_host)"
    case "$host" in
        localhost|127.*|::1) return ;;
    esac
    host_already_mapped "$host" && return

    if [ -t 0 ] && [ -t 1 ] && command -v sudo >/dev/null 2>&1; then
        echo ""
        echo "==> '${host}' is a custom domain -- adding '127.0.0.1  ${host}' to /etc/hosts (needs sudo):"
        if printf '127.0.0.1\t%s\n' "$host" | sudo tee -a /etc/hosts >/dev/null; then
            echo "    Done."
            return
        fi
        echo "    Couldn't add it automatically -- add this line to /etc/hosts yourself:"
        echo "      127.0.0.1  ${host}"
        return
    fi

    echo ""
    echo "==> '${host}' is a custom domain -- point it at this machine by adding this line to /etc/hosts:"
    echo "      127.0.0.1  ${host}"
}

# Prompts the user to pick one of several options by number, for choices that must
# come from a known-compatible list (e.g. PHP versions for a given Magento version)
# rather than free text -- so an incompatible value can never be typed in. The
# first option is the default (plain Enter accepts it, marked with *). With only
# one option, skips the prompt entirely and auto-selects it, since there's nothing
# to choose between (e.g. Elasticsearch omitted when unsupported for the chosen
# Magento version). Bash functions can't return strings, so the result is left in
# $REPLY_VALUE (mirroring how `read` uses $REPLY).
#
# Usage: choose_from_list "PHP version" 8.3 8.4 8.5
# Sets:  REPLY_VALUE=<chosen>
choose_from_list() {
    local label="$1"
    shift
    local options=("$@")

    if [ "${#options[@]}" -eq 1 ]; then
        echo "  ${label}: ${options[0]} (only option compatible with your selection)"
        REPLY_VALUE="${options[0]}"
        return
    fi

    echo "  Choose ${label} (Enter for the default, marked with *):"
    local i
    for i in "${!options[@]}"; do
        local marker=""
        [ "$i" -eq 0 ] && marker=" *"
        printf '    %d) %s%s\n' "$((i + 1))" "${options[$i]}" "$marker"
    done

    local choice
    read -rp "  Select [1-${#options[@]}]: " choice
    if [ -z "$choice" ]; then
        REPLY_VALUE="${options[0]}"
        return
    fi
    case "$choice" in
        *[!0-9]*) die "Invalid selection '${choice}'." ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ] || \
        die "Invalid selection '${choice}'. Choose a number between 1 and ${#options[@]}."
    REPLY_VALUE="${options[$((choice - 1))]}"
}

# Run a command inside the php container as www-data. `_t` variant disables the
# pseudo-TTY, for use in scripted/non-interactive contexts (piped output, CI).
php_exec()   { docker compose exec --user www-data php "$@"; }
php_exec_t() { docker compose exec --user www-data -T php "$@"; }

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        [ -f ".env.example" ] || die ".env and .env.example not found in $(pwd)"
        echo "==> No .env found, creating one from .env.example"
        cp .env.example "$ENV_FILE"
    fi
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    # Fallbacks for .env files predating a given setting.
    : "${MAGENTO_REPO_URL:=https://github.com/magento/magento2.git}"
    : "${SEARCH_ENGINE:=opensearch}"

    # HOST_UID/HOST_GID must match whoever is actually running this command, or
    # every file the php container writes to the bind-mounted public_html/ (owned
    # by www-data, remapped to these values at image build time) ends up with the
    # wrong owner on the host -- "permission denied" editing/deleting them outside
    # Docker, and vice versa if the host already owns files the container can't
    # then write to. .env.example ships a static 1000/1000 fallback (right for the
    # first user on most Linux installs, wrong for anyone else -- a second account,
    # WSL, macOS, CI), so re-sync to the real caller on every load instead of
    # trusting whatever's on disk.
    local real_uid real_gid
    real_uid="$(id -u)"
    real_gid="$(id -g)"
    if [ "${HOST_UID:-}" != "$real_uid" ] || [ "${HOST_GID:-}" != "$real_gid" ]; then
        set_env_var HOST_UID "$real_uid"
        set_env_var HOST_GID "$real_gid"
        HOST_UID="$real_uid"
        HOST_GID="$real_gid"
        echo "==> Synced HOST_UID/HOST_GID in .env to your user (${real_uid}:${real_gid})."
        echo "    If the php image was already built with different values, run: docker compose build php"
    fi
}

# Updates KEY=VALUE in .env, adding the line if it isn't already there (older
# .env files predate settings like MARIADB_VERSION or SEARCH_ENGINE).
set_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

# Counts how many of the given milestone substrings have appeared so far in
# `docker compose logs <service>` -- this is the container's own real, observable
# output, not a guess. Order isn't enforced (a warm restart skips the early
# first-init milestones entirely and jumps straight to the late ones), so this counts
# presence, not sequence. Prints the count on stdout.
milestones_seen() {
    local service="$1"
    shift
    local logs
    logs="$(docker compose logs --no-color "$service" 2>/dev/null || true)"
    local seen=0 m
    for m in "$@"; do
        case "$logs" in
            *"$m"*) seen=$((seen + 1)) ;;
        esac
    done
    printf '%s\n' "$seen"
}

# Polls `check_cmd` every 2s until it succeeds, showing a progress bar so a long wait
# (MariaDB/search engine cold start) doesn't look hung. The bar's fill is real, not a
# time-based guess: it's driven by counting known startup milestones (e.g. "Database
# files initialized", "ready for connections") as they actually appear in the
# service's own container logs -- see MARIADB_MILESTONES / SEARCH_MILESTONES below.
# It can jump unevenly (a warm restart skips straight to the late milestones) since
# milestones aren't evenly spaced in time, but every # on the bar corresponds to a
# real, already-happened event, never a projection. On a real terminal the bar
# updates in place (\r); when stdout isn't a terminal (piped to a log file, CI) it
# instead prints one plain line every ~10s, since \r wouldn't render usefully there.
#
# Usage: wait_until <label> <compose service> <milestone>... -- <check_cmd...>
wait_until() {
    local label="$1" service="$2"
    shift 2

    local milestones=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        milestones+=("$1")
        shift
    done
    shift # drop the -- separator

    echo "==> Waiting for ${label}..."

    local waited=0 interval=2 width=30
    local total=${#milestones[@]}

    until "$@" >/dev/null 2>&1; do
        if [ -t 1 ]; then
            local seen=0 pct=0 filled empty bar
            if [ "$total" -gt 0 ]; then
                seen="$(milestones_seen "$service" "${milestones[@]}")"
                pct=$(( seen * 100 / total ))
            fi
            filled=$(( pct * width / 100 ))
            empty=$(( width - filled ))
            bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '.')"
            printf '\r    [%s] %3d%% (%ds elapsed)\033[K' "$bar" "$pct" "$waited"
        elif [ "$waited" -gt 0 ] && [ $((waited % 10)) -eq 0 ]; then
            echo "    still waiting on ${label}... (${waited}s elapsed)"
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [ -t 1 ]; then
        printf '\r\033[K'
    fi
    echo "    ${label} is ready (${waited}s elapsed)."
}

# Real, observable phases from MariaDB's own docker-entrypoint.sh output on a cold
# (first-run) start. A warm restart only ever produces the last one or two of these,
# jumping straight to a high percentage -- which is accurate, since a restart really
# does skip all the earlier one-time setup work.
MARIADB_MILESTONES=(
    "Initializing database files"
    "Database files initialized"
    "Temporary server started"
    "Creating database"
    "MariaDB init process done"
    "ready for connections"
)

# MariaDB 11.x dropped the legacy `mysqladmin` binary (renamed to `mariadb-admin` as
# part of moving its client tools off MySQL-branded names) -- `mariadb-admin` is the
# one name that exists across every MariaDB version in lib/versions.tsv (10.6 through
# 11.8), so it's the only one safe to depend on here.
wait_for_db() {
    wait_until "MariaDB" db "${MARIADB_MILESTONES[@]}" -- \
        docker compose exec -T db mariadb-admin ping -h 127.0.0.1 -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent
}

# Real, observable phases from the search engine's own JVM node startup log.
# OpenSearch is a fork of Elasticsearch 7.10.2 and both still share this same
# underlying Node lifecycle logging, so one milestone list covers either engine.
SEARCH_MILESTONES=(
    "] initialized"
    "] starting ..."
    "cluster UUID set to"
    "publish_address"
    "] started"
)

# Waits for whichever search engine is configured -- OpenSearch and Elasticsearch
# both expose the same _cluster/health endpoint.
wait_for_search() {
    wait_until "$(search_engine_label)" "${SEARCH_ENGINE}" "${SEARCH_MILESTONES[@]}" -- \
        curl -sf "http://localhost:${SEARCH_PORT}/_cluster/health"
}

# Human-readable label for the configured search engine, for status output.
search_engine_label() {
    case "$SEARCH_ENGINE" in
        opensearch)    echo "OpenSearch" ;;
        elasticsearch) echo "Elasticsearch" ;;
        *)             echo "$SEARCH_ENGINE" ;;
    esac
}

# Prints every URL/credential needed to reach the running stack. Call after any
# command that (re)starts containers, once .env has been loaded into the shell.
print_urls() {
    echo ""
    echo "Shop '${COMPOSE_PROJECT_NAME}' is up:"
    echo "  Storefront:  ${BASE_URL}"
    echo "  Admin:       ${BASE_URL%/}/${ADMIN_FRONTNAME:-admin}  (${ADMIN_USER} / ${ADMIN_PASSWORD})"
    echo "  HTTPS:       https://localhost:${NGINX_SSL_PORT}/  (same site, locally-trusted mkcert cert -- see ./magento certs)"
    echo "  phpMyAdmin:  http://localhost:${PHPMYADMIN_PORT}  (${MYSQL_USER} / ${MYSQL_PASSWORD})"
    echo "  Mailpit:     http://localhost:${MAILPIT_HTTP_PORT}"
    echo "  $(search_engine_label):  http://localhost:${SEARCH_PORT}"
    ensure_hosts_entry
}
