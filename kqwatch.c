// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Ricardo J. Rodríguez, Universidad de Zaragoza
/*
 * kqwatch: attach and detach an EVFILT_VNODE kqueue watch on each path,
 * `rounds` times. Every attach makes XNU call VNOP_MONITOR(BEGIN) and every
 * detach VNOP_MONITOR(END) (bsd/vfs/vfs_vnops.c, filt_vnattach/filt_vndetach),
 * which macFUSE forwards to the filesystem as FUSE_MONITOR.
 *
 * usage: kqwatch <rounds> <path>...
 */
#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	if (argc < 3)
		errx(2, "usage: %s <rounds> <path>...", argv[0]);
	int rounds = atoi(argv[1]);

	for (int r = 0; r < rounds; r++) {
		for (int i = 2; i < argc; i++) {
			int fd = open(argv[i], O_EVTONLY);
			if (fd < 0)
				err(1, "open %s", argv[i]);
			int kq = kqueue();
			if (kq < 0)
				err(1, "kqueue");
			struct kevent ev;
			EV_SET(&ev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
			       NOTE_WRITE | NOTE_DELETE | NOTE_RENAME, 0, NULL);
			if (kevent(kq, &ev, 1, NULL, 0, NULL) < 0)
				err(1, "kevent %s", argv[i]);
			close(kq); /* detach -> MONITOR(END) */
			close(fd);
		}
	}
	printf("kqwatch: %d round(s) on %d path(s)\n", rounds, argc - 2);
	return 0;
}
