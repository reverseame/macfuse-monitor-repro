CFLAGS := -O1 -g -Wall -Wextra -D_FILE_OFFSET_BITS=64
HERE   := $(abspath .)
V513   := v513/lib/libfuse.2.dylib

all: memfs-513 memfs-550 kqwatch

# Affected user-space libfuse from the official macFUSE 5.1.3 release
# (downloaded and SHA-256 verified; nothing is installed).
$(V513):
	scripts/fetch-macfuse.sh 5.1.3 v513

# memfs linked against the affected libfuse, loaded from ./v513 instead of
# /usr/local/lib.
memfs-513: memfs.c $(V513)
	cc $(CFLAGS) -Iv513/include/fuse -o $@ memfs.c $(V513) -pthread
	install_name_tool -change /usr/local/lib/libfuse.2.dylib $(HERE)/$(V513) $@
	codesign -f -s - $@ 2>/dev/null

# memfs linked against the installed (fixed) libfuse.
memfs-550: memfs.c
	cc $(CFLAGS) -I/usr/local/include/fuse -o $@ memfs.c /usr/local/lib/libfuse.2.dylib -pthread

kqwatch: kqwatch.c
	cc $(CFLAGS) -o $@ kqwatch.c

clean:
	rm -rf memfs-513 memfs-550 kqwatch *.dSYM

distclean: clean
	rm -rf v513 logs mnt-513 mnt-550

.PHONY: all clean distclean
