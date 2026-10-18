/* duo2-home: get the Surface Duo 2 back to fastboot without a person.
 *
 *   duo2-home                reboot to the bootloader now
 *   duo2-home --watch [N]    in the background: if after N seconds (default
 *                            from duo2.home=N on the command line, else 120)
 *                            PID 1 is still running from the initramfs,
 *                            reboot to the bootloader; once the real root
 *                            has taken over, exit quietly
 *
 * postmarketOS's initramfs ends any failure in a debug shell and an endless
 * loop, and busybox's reboot cannot pass a reboot argument, so nothing in
 * there can send the phone back to fastboot. This can, by name, as
 * /usr/bin/bootloader -- the same command the bring-up init and the booted
 * system answer to, so duo2-bootloader.sh works at every stage.
 *
 * "Still in the initramfs" is decided by comparing the root directory of
 * PID 1 with this process's own: switch_root changes PID 1's, never ours.
 */
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define WATCH_DEFAULT 120

static void home(void)
{
    sync();
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_RESTART2, "bootloader");
    _exit(1);
}

static long watch_seconds(void)
{
    char cmdline[2048] = "";
    int fd = open("/proc/cmdline", O_RDONLY);
    const char *p;

    if (fd >= 0) {
        if (read(fd, cmdline, sizeof(cmdline) - 1) < 0)
            cmdline[0] = '\0';
        close(fd);
    }
    p = strstr(cmdline, "duo2.home=");
    return p ? strtol(p + 10, NULL, 10) : WATCH_DEFAULT;
}

int main(int argc, char **argv)
{
    const char *name = strrchr(argv[0], '/');
    struct stat ours, pid1;
    long secs;

    name = name ? name + 1 : argv[0];
    if (argc < 2 || strcmp(argv[1], "--watch"))
        home();

    secs = argc > 2 ? strtol(argv[2], NULL, 10) : watch_seconds();
    if (secs <= 0)
        return 0;
    if (fork() > 0)
        return 0;
    setsid();
    sleep(secs);
    if (stat("/", &ours) || stat("/proc/1/root/", &pid1))
        return 0;
    if (ours.st_dev == pid1.st_dev && ours.st_ino == pid1.st_ino) {
        fprintf(stderr, "%s: still in the initramfs after %ld s, "
                "rebooting to the bootloader\n", name, secs);
        home();
    }
    return 0;
}
