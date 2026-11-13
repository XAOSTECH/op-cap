/* usbreset.c - small utility to usb reset a device node using ioctl */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

int main(int argc, char **argv) {
    const char *filename;
    int fd;
    const char *base = "/dev/bus/usb/";
    char resolved[PATH_MAX];

    if (argc != 2) {
        fprintf(stderr, "Usage: usbreset <device-node (e.g. /dev/bus/usb/001/002)>\n");
        return 1;
    }
    filename = argv[1];

    if (filename[0] != '/' || strstr(filename, "..") != NULL || strchr(filename, '\\') != NULL ||
        strncmp(filename, base, strlen(base)) != 0) {
        fprintf(stderr, "Invalid device path. Must be under /dev/bus/usb/.\n");
        return 1;
    }

    if (realpath(filename, resolved) == NULL) {
        perror("Error resolving device path");
        return 1;
    }

    if (strncmp(resolved, base, strlen(base)) != 0) {
        fprintf(stderr, "Resolved path escapes /dev/bus/usb/.\n");
        return 1;
    }

    fd = open(resolved, O_WRONLY);
    if (fd < 0) {
        perror("Error opening device");
        return 1;
    }
    if (ioctl(fd, USBDEVFS_RESET, 0) < 0) {
        perror("Error in ioctl");
        close(fd);
        return 1;
    }
    printf("Reset successful on %s\n", resolved);
    close(fd);
    return 0;
}
