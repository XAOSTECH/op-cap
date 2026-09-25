/* LD_PRELOAD shim: blocks OBS from opening /dev/video* and /dev/v4l* nodes
 * when launched via obs-safe-launch --no-device. Built by make build. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <string.h>

static int starts_with(const char *s, const char *p) {
    return s && p && strncmp(s, p, strlen(p)) == 0;
}

static int block_path(const char *path) {
    return starts_with(path, "/dev/video") ||
           starts_with(path, "/dev/v4l") ||
           starts_with(path, "/sys/class/video4linux") ||
           starts_with(path, "/sys/devices/virtual/video4linux");
}

typedef int (*open_fn_t)(const char *, int, ...);
typedef int (*openat_fn_t)(int, const char *, int, ...);
typedef DIR *(*opendir_fn_t)(const char *);

int open(const char *pathname, int flags, ...) {
    static open_fn_t real_open = NULL;
    if (!real_open) real_open = (open_fn_t)dlsym(RTLD_NEXT, "open");
    if (block_path(pathname)) { errno = ENOENT; return -1; }
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t); va_end(ap);
    return real_open(pathname, flags, mode);
}

int open64(const char *pathname, int flags, ...) {
    static open_fn_t real_open64 = NULL;
    if (!real_open64) real_open64 = (open_fn_t)dlsym(RTLD_NEXT, "open64");
    if (block_path(pathname)) { errno = ENOENT; return -1; }
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t); va_end(ap);
    return real_open64(pathname, flags, mode);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    static openat_fn_t real_openat = NULL;
    if (!real_openat) real_openat = (openat_fn_t)dlsym(RTLD_NEXT, "openat");
    if (block_path(pathname)) { errno = ENOENT; return -1; }
    va_list ap; va_start(ap, flags);
    mode_t mode = va_arg(ap, mode_t); va_end(ap);
    return real_openat(dirfd, pathname, flags, mode);
}

DIR *opendir(const char *name) {
    static opendir_fn_t real_opendir = NULL;
    if (!real_opendir) real_opendir = (opendir_fn_t)dlsym(RTLD_NEXT, "opendir");
    if (block_path(name)) { errno = ENOENT; return NULL; }
    return real_opendir(name);
}
