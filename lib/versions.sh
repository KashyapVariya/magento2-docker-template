#!/usr/bin/env bash
# Shared helpers for reading lib/versions.tsv -- the Magento <-> PHP / MariaDB /
# OpenSearch / Elasticsearch / Composer compatibility matrix.
#
# Sourced automatically by lib/common.sh; don't source directly unless you
# specifically want the lookup helpers without the rest of common.sh.
#
# Exported helpers:
#   versions_lookup <magento_version>
#       Prints a TAB-separated row "php<TAB>mariadb<TAB>opensearch<TAB>elasticsearch<TAB>composer"
#       on stdout, or returns 1 if no row matches.
#   versions_prefix_match <prefix> <version>
#       Returns 0 if <prefix> is a boundary-aware prefix of <version>.

versions_tsv_path() {
    # Prefer a path relative to the current working directory: every caller in this
    # project keeps CWD pinned at the project root (see lib/common.sh), and that
    # stays correct even when bin/init renames the project directory mid-run (the
    # BASH_SOURCE-derived path below goes stale the moment that happens, since it's
    # the absolute path this file was originally sourced from).
    if [ -f "lib/versions.tsv" ]; then
        printf '%s\n' "lib/versions.tsv"
        return
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s\n' "$script_dir/versions.tsv"
}

# Boundary-aware prefix match. Returns 0 if `version` starts with `prefix` AND the
# next character is either end-of-string, `.`, or `-`. This makes prefix "2.4.7"
# match "2.4.7", "2.4.7-p10", and "2.4.7.0" but NOT "2.4.70".
versions_prefix_match() {
    local prefix="$1"
    local version="$2"
    case "$version" in
        "$prefix"|"$prefix".*|"$prefix"-*) return 0 ;;
        *) return 1 ;;
    esac
}

# Prints the matching row's columns (tab-separated: php mariadb opensearch
# elasticsearch composer) on stdout. Returns 1 with no output if nothing matches.
# Rows are scanned top-to-bottom; the first match wins.
versions_lookup() {
    local version="$1"
    local tsv
    tsv="$(versions_tsv_path)"

    [ -f "$tsv" ] || return 1
    [ -n "$version" ] || return 1

    local row_prefix php mariadb opensearch elasticsearch composer
    while IFS=$'\t' read -r row_prefix php mariadb opensearch elasticsearch composer; do
        case "$row_prefix" in
            ''|'#'*) continue ;;
        esac
        if versions_prefix_match "$row_prefix" "$version"; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$php" "$mariadb" "$opensearch" "$elasticsearch" "$composer"
            return 0
        fi
    done < "$tsv"

    return 1
}
