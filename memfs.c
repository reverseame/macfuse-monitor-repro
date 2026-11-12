// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Ricardo J. Rodríguez, Universidad de Zaragoza
/*
 * memfs: minimal in-memory FUSE 2.x high-level filesystem used to reproduce
 * the macFUSE FUSE_MONITOR path-lock leak (macfuse/macfuse#1168).
 *
 * It deliberately does NOT implement the .monitor operation: in affected
 * macFUSE versions (5.1.0 - 5.3.0) libfuse still takes the path lock for
 * every FUSE_MONITOR message and never releases it.
 */
#define FUSE_USE_VERSION 26
#include <errno.h>
#include <fuse.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_ENTRIES 1024

struct entry {
	char *path;
	mode_t mode;
	char *data;
	size_t size;
	struct timespec mtime;
};

static struct entry entries[MAX_ENTRIES];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static struct entry *find(const char *path)
{
	for (int i = 0; i < MAX_ENTRIES; i++)
		if (entries[i].path && strcmp(entries[i].path, path) == 0)
			return &entries[i];
	return NULL;
}

static struct entry *add(const char *path, mode_t mode)
{
	for (int i = 0; i < MAX_ENTRIES; i++) {
		if (!entries[i].path) {
			entries[i].path = strdup(path);
			entries[i].mode = mode;
			entries[i].data = NULL;
			entries[i].size = 0;
			clock_gettime(CLOCK_REALTIME, &entries[i].mtime);
			return &entries[i];
		}
	}
	return NULL;
}

static void drop(struct entry *e)
{
	free(e->path);
	free(e->data);
	memset(e, 0, sizeof(*e));
}

/* Is `child` a direct child of `dir`? */
static const char *child_name(const char *dir, const char *child)
{
	size_t n = strlen(dir);
	if (strcmp(dir, "/") == 0)
		n = 0;
	if (strncmp(child, dir, n) != 0 || child[n] != '/' || child[n + 1] == '\0')
		return NULL;
	if (strchr(child + n + 1, '/'))
		return NULL;
	return child + n + 1;
}

static int has_children(const char *dir)
{
	for (int i = 0; i < MAX_ENTRIES; i++)
		if (entries[i].path && child_name(dir, entries[i].path))
			return 1;
	return 0;
}

static int m_getattr(const char *path, struct stat *st)
{
	int ret = 0;
	memset(st, 0, sizeof(*st));
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e) {
		ret = -ENOENT;
	} else {
		st->st_mode = e->mode;
		st->st_nlink = S_ISDIR(e->mode) ? 2 : 1;
		st->st_size = (off_t)e->size;
		st->st_uid = getuid();
		st->st_gid = getgid();
		st->st_mtimespec = e->mtime;
		st->st_ctimespec = e->mtime;
		st->st_atimespec = e->mtime;
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
		     off_t off, struct fuse_file_info *fi)
{
	(void)off;
	(void)fi;
	filler(buf, ".", NULL, 0);
	filler(buf, "..", NULL, 0);
	pthread_mutex_lock(&lock);
	for (int i = 0; i < MAX_ENTRIES; i++) {
		const char *name;
		if (entries[i].path && (name = child_name(path, entries[i].path)))
			filler(buf, name, NULL, 0);
	}
	pthread_mutex_unlock(&lock);
	return 0;
}

static int m_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
	(void)fi;
	int ret = 0;
	pthread_mutex_lock(&lock);
	if (find(path))
		ret = -EEXIST;
	else if (!add(path, S_IFREG | (mode & 07777)))
		ret = -ENOSPC;
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_mkdir(const char *path, mode_t mode)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	if (find(path))
		ret = -EEXIST;
	else if (!add(path, S_IFDIR | (mode & 07777)))
		ret = -ENOSPC;
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_open(const char *path, struct fuse_file_info *fi)
{
	(void)fi;
	pthread_mutex_lock(&lock);
	int ret = find(path) ? 0 : -ENOENT;
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_read(const char *path, char *buf, size_t size, off_t off,
		  struct fuse_file_info *fi)
{
	(void)fi;
	int ret;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e) {
		ret = -ENOENT;
	} else if ((size_t)off >= e->size) {
		ret = 0;
	} else {
		if (off + size > e->size)
			size = e->size - (size_t)off;
		memcpy(buf, e->data + off, size);
		ret = (int)size;
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_write(const char *path, const char *buf, size_t size, off_t off,
		   struct fuse_file_info *fi)
{
	(void)fi;
	int ret;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e) {
		ret = -ENOENT;
	} else {
		size_t end = (size_t)off + size;
		if (end > e->size) {
			char *nd = realloc(e->data, end);
			if (!nd) {
				pthread_mutex_unlock(&lock);
				return -ENOMEM;
			}
			memset(nd + e->size, 0, end - e->size);
			e->data = nd;
			e->size = end;
		}
		memcpy(e->data + off, buf, size);
		clock_gettime(CLOCK_REALTIME, &e->mtime);
		ret = (int)size;
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_truncate(const char *path, off_t size)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e) {
		ret = -ENOENT;
	} else {
		char *nd = realloc(e->data, size ? (size_t)size : 1);
		if (!nd) {
			ret = -ENOMEM;
		} else {
			if ((size_t)size > e->size)
				memset(nd + e->size, 0, (size_t)size - e->size);
			e->data = nd;
			e->size = (size_t)size;
		}
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_unlink(const char *path)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e)
		ret = -ENOENT;
	else
		drop(e);
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_rmdir(const char *path)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e)
		ret = -ENOENT;
	else if (has_children(path))
		ret = -ENOTEMPTY;
	else
		drop(e);
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_rename(const char *from, const char *to)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(from);
	if (!e) {
		ret = -ENOENT;
	} else if (S_ISDIR(e->mode) && has_children(from)) {
		ret = -EXDEV; /* keep the toy simple */
	} else {
		struct entry *t = find(to);
		if (t)
			drop(t);
		free(e->path);
		e->path = strdup(to);
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_utimens(const char *path, const struct timespec tv[2])
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e)
		ret = -ENOENT;
	else
		e->mtime = tv[1];
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_chmod(const char *path, mode_t mode)
{
	int ret = 0;
	pthread_mutex_lock(&lock);
	struct entry *e = find(path);
	if (!e)
		ret = -ENOENT;
	else
		e->mode = (e->mode & S_IFMT) | (mode & 07777);
	pthread_mutex_unlock(&lock);
	return ret;
}

static int m_chown(const char *path, uid_t uid, gid_t gid)
{
	(void)uid;
	(void)gid;
	pthread_mutex_lock(&lock);
	int ret = find(path) ? 0 : -ENOENT;
	pthread_mutex_unlock(&lock);
	return ret;
}

static struct fuse_operations ops = {
	.getattr = m_getattr,
	.readdir = m_readdir,
	.create = m_create,
	.mkdir = m_mkdir,
	.open = m_open,
	.read = m_read,
	.write = m_write,
	.truncate = m_truncate,
	.unlink = m_unlink,
	.rmdir = m_rmdir,
	.rename = m_rename,
	.utimens = m_utimens,
	.chmod = m_chmod,
	.chown = m_chown,
	/* .monitor intentionally left NULL */
};

int main(int argc, char *argv[])
{
	add("/", S_IFDIR | 0755);
	/* Keep Spotlight away from the test volume. */
	add("/.metadata_never_index", S_IFREG | 0644);
	return fuse_main(argc, argv, &ops, NULL);
}
