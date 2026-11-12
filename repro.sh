#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Ricardo J. Rodríguez, Universidad de Zaragoza
#
# PoC for the macFUSE FUSE_MONITOR path-lock leak (macfuse/macfuse#1168).
#
#   ./repro.sh sanity  513|550   mount, basic I/O, unmount            (no risk)
#   ./repro.sh leak    513|550   kqueue-watch a file, then rm it      (513: rm hangs; recoverable)
#   ./repro.sh wedge   513|550   kqueue-watch N files, then unmount   (513: all workers stuck in FORGET)
#   ./repro.sh cleanup 513|550   kill -9 the test fs and force-unmount
#   ./repro.sh all               every step above, both libraries; transcript in logs/transcript.txt
#
# 513 = libfuse from macFUSE 5.1.3 (affected), 550 = installed libfuse (fixed).
# Everything that can block runs under a hard timeout, and the test file system
# is killed with SIGKILL at the end of each step, so a frozen mount does not
# outlive the script. Only the throwaway memfs mounts created here are touched.
set -u
# Work with the physical path: mount(8) reports resolved paths (e.g.
# /private/tmp for /tmp), and is_mounted() compares against them.
cd "$(dirname "$0")" && ROOT=$(pwd -P)
SELF="$ROOT/$(basename "$0")"

usage() { sed -n '5,16p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2; }

STEP=${1:-}
[[ -n "$STEP" ]] || usage

if [[ "$STEP" == all ]]; then
	mkdir -p logs
	{
		for s in sanity leak wedge; do
			"$SELF" "$s" 550
			"$SELF" "$s" 513
		done
	} 2>&1 | tee logs/transcript.txt
	exit "${PIPESTATUS[0]}"
fi

V=${2:-}
[[ "$V" == 513 || "$V" == 550 ]] || usage
MNT=$ROOT/mnt-$V
LOG=$ROOT/logs/$V-$STEP.log
PIDF=$ROOT/logs/$V.pid

preflight() {
	[[ "$(uname -s)" == Darwin ]] || { echo "this PoC requires macOS" >&2; exit 1; }
	[[ -d /Library/Filesystems/macfuse.fs ]] || { echo "macFUSE is not installed" >&2; exit 1; }
	for b in "memfs-$V" kqwatch; do
		[[ -x "$b" ]] || { echo "missing ./$b: run 'make' first" >&2; exit 1; }
	done
}

say() { printf '\n== %s\n' "$*"; }

# run_to <seconds> <label> <cmd...>: run cmd in the background and SIGKILL it
# after <seconds>. Prints OK / FAILED / HUNG; returns 0 / rc / 124.
run_to() {
	local t=$1 label=$2; shift 2
	"$@" &
	local p=$! i=0 rc
	while kill -0 "$p" 2>/dev/null; do
		if (( i >= t * 10 )); then
			kill -9 "$p" 2>/dev/null
			wait "$p" 2>/dev/null
			echo "   -> HUNG (killed after ${t}s): $label"
			return 124
		fi
		sleep 0.1; i=$((i + 1))
	done
	wait "$p"; rc=$?
	if (( rc == 0 )); then echo "   -> OK: $label"; else echo "   -> FAILED rc=$rc: $label"; fi
	return "$rc"
}

is_mounted() { mount | grep -q " on $MNT "; }

# Classify the worker threads of the test file system (main loop excluded).
fs_threads() {
	local pid s="logs/$V-$STEP.sample.txt"
	pid=$(cat "$PIDF" 2>/dev/null) || return
	kill -0 "$pid" 2>/dev/null || { echo "   (fs process gone)"; return; }
	sample "$pid" 1 -file "$s" >/dev/null 2>&1
	awk '
		function flush() { if (t != "" && !main) { if (cw) w++; else if (rd) r++; else o++ } }
		/^    [0-9]+ Thread_/ { flush(); t = $2; main = cw = rd = 0; next }
		/fuse_session_loop_mt/ { main = 1 }
		/pthread_cond_wait/ { cw = 1 }
		/ read  \(in libsystem_kernel/ { rd = 1 }
		/^Total number in stack/ { exit }
		END { flush(); printf "   workers: blocked in pthread_cond_wait=%d, reading /dev/macfuse=%d, other=%d\n", w, r, o }
	' "$s"
	echo "   (fs pid $pid; stacks: $s)"
}

do_mount() {
	if is_mounted; then echo "already mounted: $MNT (run: $SELF cleanup $V)"; exit 1; fi
	mkdir -p logs "$MNT"
	: > "$LOG"
	"./memfs-$V" "$MNT" -d \
		-o "nobrowse,noappledouble,noapplexattr,volname=memfs-$V,fsname=memfs-$V" \
		>>"$LOG" 2>&1 &
	echo $! > "$PIDF"
	for _ in $(seq 50); do is_mounted && break; sleep 0.1; done
	if ! is_mounted; then
		echo "mount FAILED; log tail:"; tail -20 "$LOG"; cleanup; exit 1
	fi
	echo "   mounted $MNT (pid $(cat "$PIDF"), debug log logs/$V-$STEP.log)"
}

cleanup() {
	local pid
	pid=$(cat "$PIDF" 2>/dev/null)
	if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid"
		wait "$pid" 2>/dev/null
		echo "   killed fs pid $pid"
	fi
	if is_mounted; then
		run_to 10 "umount -f" umount -f "$MNT" ||
			run_to 10 "diskutil unmount force" diskutil unmount force "$MNT"
	fi
	rm -f "$PIDF"
	if is_mounted; then echo "   !! still mounted: $MNT"; else echo "   unmounted"; fi
}

log_counts() {
	printf '   log: MONITOR=%s FORGET=%s "QUEUE PATH"=%s "DEQUEUE"=%s\n' \
		"$(grep -c 'opcode: MONITOR' "$LOG")" \
		"$(grep -c -E 'opcode: (BATCH_)?FORGET' "$LOG")" \
		"$(grep -c 'QUEUE PATH' "$LOG")" \
		"$(grep -c 'DEQUEUE' "$LOG")"
}

trap 'echo; echo "interrupted; cleaning up"; cleanup; exit 130' INT TERM

case $STEP in
sanity)
	preflight
	say "sanity: libfuse $V"
	do_mount
	run_to 10 "write, read, list, remove a file" \
		sh -c "echo hello > '$MNT/f' && cat '$MNT/f' >/dev/null && ls '$MNT' >/dev/null && rm '$MNT/f'"
	run_to 15 "umount" umount "$MNT"
	cleanup
	;;
leak)
	preflight
	say "leak: libfuse $V"
	do_mount
	run_to 10 "create d/x" sh -c "mkdir '$MNT/d' && echo data > '$MNT/d/x'"
	run_to 10 "kqwatch: attach/detach a kqueue watch on d/x 3 times" ./kqwatch 3 "$MNT/d/x"
	sleep 1; log_counts
	run_to 10 "rm d/x (needs a write lock on x)" rm "$MNT/d/x"
	sleep 1; log_counts
	grep -E 'QUEUE PATH' "$LOG" | sed 's/^/   /' | head -5
	fs_threads
	cleanup
	;;
wedge)
	preflight
	N=${N:-24}
	say "wedge: libfuse $V, $N files"
	do_mount
	run_to 20 "create $N files" sh -c "for i in \$(seq -w 1 $N); do echo \$i > '$MNT/f'\$i; done"
	run_to 20 "kqwatch: attach/detach a kqueue watch on each file" ./kqwatch 1 "$MNT"/f*
	sleep 1; log_counts
	fs_threads
	run_to 20 "umount (the kernel reclaims every vnode: one FORGET each)" umount "$MNT"
	sleep 1; log_counts
	fs_threads
	cleanup
	;;
cleanup)
	cleanup
	;;
*)
	usage
	;;
esac
