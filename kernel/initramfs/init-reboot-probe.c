/* Reboot probe: proves the kernel runs when there is no way to see it.
 *
 * The Duo 2 has no debug UART, and mainline has no display driver for it, so
 * a kernel that boots perfectly leaves the bootloader's Microsoft logo on
 * screen and says nothing. Silence is therefore not evidence of failure, and
 * the usual "did it boot" signals are all unavailable.
 *
 * This init waits a known number of seconds and then reboots deliberately.
 * The host sees the phone drop off USB and re-enumerate at that exact moment.
 * A reboot on schedule means the kernel started, unpacked the initramfs and
 * ran userspace; nothing happening means it never got that far. Either way
 * the answer arrives without a console.
 */
#include <unistd.h>
#include <stdio.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <fcntl.h>

#define WAIT_SECONDS 20

int main(void)
{
    mount("proc",  "/proc", "proc",  0, NULL);
    mount("sysfs", "/sys",  "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) { dup2(fd, 0); dup2(fd, 1); dup2(fd, 2); }

    /* Printed in case a console does exist after all. */
    for (int i = 0; i < WAIT_SECONDS; i++) {
        printf("[duo2-probe] alive %d/%d, rebooting at %d\n",
               i, WAIT_SECONDS, WAIT_SECONDS);
        fflush(stdout);
        sleep(1);
    }

    sync();
    reboot(RB_AUTOBOOT);
    for (;;) pause();
}
