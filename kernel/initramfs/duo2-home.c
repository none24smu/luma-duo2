/* duo2-home: get the Surface Duo 2 back to fastboot without a person.
 *
 *   duo2-home           reboot to the bootloader now
 *   duo2-home --watch   in the background, in two phases:
 *     1. after duo2.home=N seconds (default 120), if PID 1 is still running
 *        from the initramfs, reboot to the bootloader;
 *     2. after duo2.booted=N seconds from the start (default 300), if the
 *        booted system has not created /run/luma-duo2-booted, reboot to the
 *        bootloader. luma-duo2-booted.service creates it once
 *        multi-user.target is reached. 0 disables either phase.
 *
 * postmarketOS's initramfs ends any failure in a debug shell and an endless
 * loop, and busybox's reboot cannot pass a reboot argument, so nothing in
 * there can send the phone back to fastboot. The booted system can fail the
 * same way: a systemd that cannot spawn services leaves no shell to ask.
 * This covers both. It is also /usr/bin/bootloader in the initramfs -- the
 * same command the bring-up init and the booted system answer to, so
 * duo2-bootloader.sh works at every stage.
 *
 * "Still in the initramfs" is decided by comparing the root directory of
 * PID 1 with this process's own: switch_root changes PID 1's, never ours. The
 * booted system's /run is reached through /proc/1/root for the same reason.
 */
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define HOME_DEFAULT    120
#define BOOTED_DEFAULT  300
#define MARKER          "/proc/1/root/run/luma-duo2-booted"

static void home(const char *why)
{
    if (why)
        fprintf(stderr, "duo2-home: %s, rebooting to the bootloader\n", why);
    sync();
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_RESTART2, "bootloader");
    _exit(1);
}

static long param(const char *cmdline, const char *key, long fallback)
{
    const char *p = strstr(cmdline, key);

    return p ? strtol(p + strlen(key), NULL, 10) : fallback;
}

static int still_in_initramfs(void)
{
    struct stat ours, pid1;

    if (stat("/", &ours) || stat("/proc/1/root/", &pid1))
        return 0;
    return ours.st_dev == pid1.st_dev && ours.st_ino == pid1.st_ino;
}

int main(int argc, char **argv)
{
    char cmdline[2048] = "";
    long first, total;
    int fd;

    if (argc < 2 || strcmp(argv[1], "--watch"))
        home(NULL);

    fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) {
        if (read(fd, cmdline, sizeof(cmdline) - 1) < 0)
            cmdline[0] = '\0';
        close(fd);
    }
    first = param(cmdline, "duo2.home=", HOME_DEFAULT);
    total = param(cmdline, "duo2.booted=", BOOTED_DEFAULT);

    if (fork() > 0)
        return 0;
    setsid();

    if (first > 0) {
        sleep(first);
        if (still_in_initramfs())
            home("still in the initramfs");
    }
    if (total > 0) {
        if (total > first)
            sleep(total - (first > 0 ? first : 0));
        if (access(MARKER, F_OK))
            home("booted system never reached multi-user.target");
    }
    return 0;
}
