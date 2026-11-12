# macfuse-monitor-repro

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Proof of concept for the **`FUSE_MONITOR` path-lock leak in macFUSE's
user-space `libfuse` 2** ([macfuse/macfuse#1168](https://github.com/macfuse/macfuse/issues/1168)),
and for how it escalates from a single stuck operation into a **fully frozen
FUSE volume** (every worker thread parked in `forget_node()`, nobody reading
`/dev/macfuse`, `umount` and system shutdown stalled).

| | |
|---|---|
| Affected | macFUSE **5.1.0 – 5.3.0** (high-level `libfuse` 2 API: EncFS, SSHFS, ...) |
| Fixed | macFUSE **5.3.1** (June 13, 2026) |
| Introduced by | [`67aa41ee`](https://github.com/macfuse/library/commit/67aa41ee6c8456180526e1023217a1c6a3eff921) "Add support for FUSE_MONITOR message on macOS" (Oct 23, 2025) |
| Fixed by | [`c3ff8d98`](https://github.com/macfuse/library/commit/c3ff8d98e06c7194591dbf8076da4ada1c97f519) "Add missing free_path() call in fuse_lib_monitor()" (Jun 8, 2026) |
| Impact | Local denial of service of the FUSE volume ([CWE-772](https://cwe.mitre.org/data/definitions/772.html) leading to [CWE-833](https://cwe.mitre.org/data/definitions/833.html)) |
| Trigger | Any process that can open a file on the volume: `open(O_EVTONLY)` + a kqueue `EVFILT_VNODE` filter |

The full story (shutdown-stall forensics, source and binary analysis) is in our
blog post *"Watch Out for Your Watchers: How a PDF Preview Froze Our Encrypted
Folders (and a One-Line Bug in macFUSE)"* on [reversea.me](https://reversea.me/).

> **This is a PoC for an already public and fixed bug.** It only mounts and
> freezes its own throwaway in-memory file systems, never your existing
> volumes. If you run macFUSE 5.1.0–5.3.0 for real data, the fix is simply to
> update macFUSE (see [Mitigation](#mitigation)).

---

## The bug in a nutshell

In the high-level `libfuse` API, every path-based request read-locks the path:
`get_path()` increments `treelock` on the node **and on every ancestor
directory**, and `free_path()` undoes it. The `FUSE_MONITOR` handler added in
macFUSE 5.1.0 forgot the second half:

```c
static void fuse_lib_monitor(fuse_req_t req, fuse_ino_t ino, uint32_t flags)
{
	...
	err = get_path(f, ino, &path);      /* read lock taken */
	...
	fuse_fs_monitor(f->fs, path, flags);
	fuse_reply_none(req);               /* missing free_path(): never released */
}
```

The kernel sends `FUSE_MONITOR` whenever a kqueue filter is attached to or
detached from a vnode (XNU `filt_vnattach()` / `filt_vndetach()` call
`VNOP_MONITOR(BEGIN|END)`), so **every file watch leaks two read locks**. The
handler is registered unconditionally, so file systems that do not implement
`.monitor` (EncFS, for instance) are affected too.

Two consequences follow:

1. **Single stuck operation** (the symptom reported in #1168): `unlink`,
   `rmdir` or `rename` of the watched file or of one of its parents needs a
   write lock, finds `treelock > 0`, and waits forever (`QUEUE PATH n (w)`
   with no `DEQUEUE`).
2. **Frozen volume**: when the kernel reclaims a leaked vnode it sends a final
   `FORGET`, and `forget_node()` waits for `treelock == 0` forever. Because
   `fuse_loop_mt.c` deliberately does not count `FORGET` workers as busy
   ("*This disgusting hack is needed so that zillions of threads are not
   created on a burst of FORGET messages*"), no replacement worker is spawned.
   Once all workers are parked, nobody reads `/dev/macfuse` anymore.

## How the PoC works

The bug lives entirely in user space (`libfuse.2.dylib`), so it can be
reproduced on a machine with a **current, fixed macFUSE**: the test file system
is linked against the `libfuse` shipped in macFUSE 5.1.3, while the kernel
extension and every other FUSE volume on the system keep using the installed,
fixed version.

| File | Purpose |
|---|---|
| `memfs.c` | Minimal in-memory high-level FUSE 2.x file system. Like EncFS, it does **not** implement `.monitor`. |
| `kqwatch.c` | A deliberately boring file watcher: attaches and detaches an `EVFILT_VNODE` kqueue filter on each path (one `MONITOR` BEGIN + END per path and round). |
| `repro.sh` | Test driver. Mounts `memfs` with `libfuse` debug output, runs every potentially blocking command under a hard timeout, samples the worker threads, and kills the test file system with `SIGKILL` at the end of each step. |
| `scripts/fetch-macfuse.sh` | Downloads an official macFUSE release and extracts its user-space `libfuse` (no installation). For 5.1.3 the disk image and `libfuse.2.dylib` are verified against pinned SHA-256 digests. |
| `scripts/check-release.sh` | Binary-level check of macFUSE releases: does `fuse_lib_monitor()` release the lock? |
| `Makefile` | Builds `memfs-513` (affected `libfuse` 5.1.3), `memfs-550` (installed `libfuse`, control) and `kqwatch`. |

No macFUSE binaries are redistributed in this repository: `make` downloads
them from the [official releases](https://github.com/macfuse/macfuse/releases).

## Requirements

* macOS with a **fixed** macFUSE installed (5.3.1 or later). Tested on macOS
  26.5.2 (Apple silicon) with macFUSE 5.5.0.
* Xcode Command Line Tools (`cc`, `otool`, `install_name_tool`, `codesign`).
* Network access for the first `make` (downloads the macFUSE 5.1.3 disk image,
  about 13 MB).

## Usage

```sh
git clone https://github.com/reverseame/macfuse-monitor-repro.git
cd macfuse-monitor-repro
make
./repro.sh all          # every step, both libraries; transcript in logs/transcript.txt
```

Or step by step (`550` = installed, fixed `libfuse`; `513` = affected `libfuse` 5.1.3):

```sh
./repro.sh sanity 513   # both libraries mount and work with the installed kext (no risk)
./repro.sh leak   550   # control: rm completes
./repro.sh leak   513   # rm hangs: QUEUE PATH n (w) without DEQUEUE
./repro.sh wedge  550   # control: unmount completes, one FORGET per file
./repro.sh wedge  513   # unmount hangs: all workers parked in pthread_cond_wait
./repro.sh cleanup 513  # kill -9 the test fs and force-unmount, if anything is left
```

Per-step `libfuse` debug logs (`logs/<lib>-<step>.log`) and thread samples
(`logs/<lib>-<step>.sample.txt`) are kept for inspection.

### Safety notes

* Only the `mnt-513/` and `mnt-550/` mount points created by the script are
  touched. They are mounted with `nobrowse` and contain a
  `.metadata_never_index` file to keep Finder and Spotlight away.
* In the `513` steps, a command on the test volume is *expected* to hang. The
  driver kills it after a timeout and then kills the test file system with
  `SIGKILL`, which makes the kernel abort the pending requests and releases the
  mount. In our runs no reboot was ever needed, but run the `513` steps with no
  important unsaved work, just in case.
* Do not open the test mount points in Finder or other apps while a step runs.

## Expected results

Run on macOS 26.5.2 (Apple silicon) with macFUSE 5.5.0 installed. The full
transcript, the `libfuse` debug logs and the thread samples of this run are in
[`results/2026-11-12/`](results/2026-11-12/).

| Step | `libfuse` | `MONITOR` | `FORGET` | `QUEUE PATH` / `DEQUEUE` | Outcome |
|---|---|---|---|---|---|
| `leak` | 5.5.0 | 6 | 0 | 0 / 0 | `rm` completes |
| `leak` | 5.1.3 | 6 | 0 | 1 / 0 (`QUEUE PATH 3 (w)`) | `rm` hangs (killed after 10 s) |
| `wedge` | 5.5.0 | 48 | 24 | 0 / 0 | unmount completes, one `FORGET` per file |
| `wedge` | 5.1.3 | 48 | 4 | 4 / 0 (`QUEUE PATH (forget)`) | unmount hangs: 4/4 workers parked in `pthread_cond_wait`, 0 reading `/dev/macfuse`; the remaining 20 `FORGET` and the `DESTROY` are never read |

The `wedge` step with the affected library looks like this:

```
== wedge: libfuse 513, 24 files
   mounted ~/macfuse-monitor-repro/mnt-513 (pid 98801, debug log logs/513-wedge.log)
   -> OK: create 24 files
kqwatch: 1 round(s) on 24 path(s)
   -> OK: kqwatch: attach/detach a kqueue watch on each file
   log: MONITOR=48 FORGET=0 "QUEUE PATH"=0 "DEQUEUE"=0
   workers: blocked in pthread_cond_wait=0, reading /dev/macfuse=4, other=0
   (fs pid 98801; stacks: logs/513-wedge.sample.txt)
   -> HUNG (killed after 20s): umount (the kernel reclaims every vnode: one FORGET each)
   log: MONITOR=48 FORGET=4 "QUEUE PATH"=4 "DEQUEUE"=0
   workers: blocked in pthread_cond_wait=4, reading /dev/macfuse=0, other=0
   (fs pid 98801; stacks: logs/513-wedge.sample.txt)
   killed fs pid 98801
   unmounted
```

and every parked worker has the same stack (verbatim from
[`results/2026-11-12/513-wedge.sample.txt`](results/2026-11-12/513-wedge.sample.txt)):

```
    +   876 _pthread_start  (in libsystem_pthread.dylib) + 136  [0x18d371c58]
    +     876 ???  (in libfuse.2.dylib)  load address 0x100704000 + 0xe924  [0x100712924]
    +       876 ???  (in libfuse.2.dylib)  load address 0x100704000 + 0x11100  [0x100715100]
    +         876 ???  (in libfuse.2.dylib)  load address 0x100704000 + 0x6674  [0x10070a674]
    +           876 ???  (in libfuse.2.dylib)  load address 0x100704000 + 0xbf08  [0x10070ff08]
    +             876 _pthread_cond_wait  (in libsystem_pthread.dylib) + 980  [0x18d372128]
    +               876 __psynch_cvwait  (in libsystem_kernel.dylib) + 8  [0x18d33150c]
```

In the 5.1.3 `libfuse.2.dylib`, `0xe924` is the worker loop (right after
`fuse_session_process_buf()`), `0x11100` the request dispatcher, `0x6674` the
`FORGET` handler (it prints `"FORGET %llu/%llu"` in debug mode), and `0xbf08`
the `pthread_cond_wait()` call inside `forget_node()`.

These are the same `libfuse` return addresses found in the macOS
shutdown-stall reports of the real EncFS freeze that motivated this work. The
number of parked workers depends on how many worker threads the file system
had alive when the `FORGET` burst arrived.

## Checking macFUSE releases at the binary level

```sh
scripts/check-release.sh 5.0.7 5.1.0 5.3.0 5.3.1 5.5.0
```

```
macFUSE   FUSE_MONITOR handler  lock released
5.0.7     no                    n/a
5.1.0     yes                   NO (leak)
5.3.0     yes                   NO (leak)
5.3.1     yes                   yes
5.5.0     yes                   yes
```

In fixed releases, `free_path()` is inlined right after the call to
`fuse_fs_monitor()` (so a `pthread_mutex_lock()` call appears before
`fuse_reply_none()`); in affected releases, nothing does.

## Mitigation

* **Update macFUSE to 5.3.1 or later.** With Homebrew, the cask is marked
  `auto_updates`, so a plain `brew upgrade` skips it (and `brew` may report a
  stale version): use `brew upgrade --cask --greedy macfuse`. The installed
  version is in
  `defaults read /Library/Filesystems/macfuse.fs/Contents/Info.plist CFBundleShortVersionString`.
  File system daemons that were already running keep the old library loaded
  until they are restarted.
* **Diagnosing a frozen volume**: `sample <pid> 1` on the file system daemon.
  Worker threads parked in `pthread_cond_wait` under the `FORGET` handler are
  the signature of this bug. `kill -9` on the daemon followed by `umount -f`
  recovers the mount point without rebooting.

## References

* macFUSE issue [#1168](https://github.com/macfuse/macfuse/issues/1168): *Path lock leak in `fuse_lib_monitor`?*
* macFUSE `libfuse` 2 fork: [macfuse/library](https://github.com/macfuse/library), branch `support/libfuse-2.9` (`lib/fuse.c`, `lib/fuse_loop_mt.c`).
* XNU: [`bsd/vfs/vfs_vnops.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_vnops.c) (`filt_vnattach()`, `filt_vndetach()`).

## AI transparency & credits

This repository is an example of **human-AI collaboration**.

* **Analysis:** the shutdown-stall forensics, the source and binary analysis,
  and the root-cause hypothesis were carried out by **R. J. Rodríguez** with the
  assistance of **Anthropic's Claude**.
* **Code:** `memfs.c`, `kqwatch.c` and the scripts were drafted by **Claude**,
  then reviewed and validated by **R. J. Rodríguez**.

## Funding support

This research was supported in part by grant PID2023-151467OA-I00 (CRAPER),
funded by MICIU/AEI/10.13039/501100011033 and by ERDF/EU, by grant
TED2021-131115A-I00 (MIMFA), funded by MICIU/AEI/10.13039/501100011033 and by
the European Union NextGenerationEU/PRTR, and the University of Zaragoza, by
grant Proyecto Estratégico Ciberseguridad EINA UNIZAR, funded by the Spanish
National Cybersecurity Institute (INCIBE) and the European Union
NextGenerationEU/PRTR, and by grant Programa de Proyectos Estratégicos de Grupos
de Investigación (DisCo research group, ref. T21-23R), funded by the
University, Industry and Innovation Department of the Aragonese Government.

## License

Licensed under the [GNU General Public License v3.0 or later](LICENSE).
macFUSE and its `libfuse` are not part of this repository; they are downloaded
from the official releases and remain under their own licenses.
