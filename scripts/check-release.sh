#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ricardo J. Rodríguez, Universidad de Zaragoza
#
# Check, at the binary level, whether a macFUSE release ships the leaky
# fuse_lib_monitor() (get_path() without free_path()).
#
#   scripts/check-release.sh 5.0.7 5.1.0 5.3.0 5.3.1 5.5.0
#
# The handler is located in the arm64 slice of libfuse.2.dylib as the function
# that calls fuse_fs_monitor() and then fuse_reply_none(). In fixed releases
# free_path() is inlined between both calls, so a pthread_mutex_lock() call
# appears there; in affected releases nothing does.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -gt 0 ]] || { echo "usage: $0 <version>..." >&2; exit 2; }
command -v otool >/dev/null || { echo "otool not found (install the Xcode command line tools)" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

printf '%-8s  %-20s  %s\n' "macFUSE" "FUSE_MONITOR handler" "lock released"
for v in "$@"; do
	scripts/fetch-macfuse.sh "$v" "$WORK/$v" >/dev/null
	otool -arch arm64 -tV "$WORK/$v/lib/libfuse.2.dylib" > "$WORK/$v.s"
	verdict=$(awk '
		/\tbl\t_fuse_fs_monitor$/ && !found { found = 1; inside = 1; next }
		inside && /pthread_mutex_lock/ { lock = 1 }
		inside && /_fuse_reply_none/ { print (lock ? "yes" : "NO (leak)"); exit }
		inside && /\tret$/ { inside = 0; found = 0 }
		END { if (!found) print "-" }
	' "$WORK/$v.s")
	if [[ "$verdict" == "-" ]]; then
		printf '%-8s  %-20s  %s\n' "$v" "no" "n/a"
	else
		printf '%-8s  %-20s  %s\n' "$v" "yes" "$verdict"
	fi
done
