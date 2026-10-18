/* Bring-up init for the Surface Duo 2.
 *
 * Two jobs: talk over the USB serial gadget (/dev/ttyGS0, ttyACM0 on the
 * host), and always get the phone back to fastboot without anyone touching
 * it. The Duo 2 has no reset pin and a hung kernel leaves the logo on screen
 * forever, so every way out of this program ends in a reboot to the
 * bootloader:
 *
 *   - the host sends "bootloader" over the port          -> fastboot now
 *   - ttyGS0 never appears (USB did not come up)         -> fastboot after
 *                                                           GADGET_WAIT s
 *   - nothing arrives from the host for duo2.idle=N s    -> fastboot
 *     (default IDLE_DEFAULT; 0 disables)
 *
 * Panics are covered by the kernel side: qcom_reboot_reason.panic_reason=
 * bootloader and download_mode=0 on the command line.
 *
 * Commands, one per line: bootloader, reboot, dmesg, help. Anything received
 * resets the idle timer.
 *
 * There is no devtmpfs in the vendor kernel, so /dev/ttyGS0 is created here
 * from the number sysfs reports rather than trusted from the initramfs.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <linux/reboot.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>

#define GADGET_WAIT   60
#define IDLE_DEFAULT  300
#define HEARTBEAT     10

static int port = -1;

static void say(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0)
        return;
    if (n > (int)sizeof(buf) - 1)
        n = sizeof(buf) - 1;
    if (port >= 0)
        write(port, buf, n);
    else
        write(2, buf, n);
}

static void restart(const char *why, const char *arg)
{
    say("[duo2-init] %s -> reboot %s\r\n", why, arg ? arg : "");
    sync();
    sleep(1);   /* let the last line leave the gadget before it drops */
    if (arg)
        syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                LINUX_REBOOT_CMD_RESTART2, arg);
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_RESTART, NULL);
    for (;;)
        pause();
}

static void dump_file(const char *path)
{
    char buf[1024];
    ssize_t n;
    int fd = open(path, O_RDONLY);

    if (fd < 0)
        return;
    while ((n = read(fd, buf, sizeof(buf))) > 0)
        if (port >= 0)
            write(port, buf, n);
    close(fd);
}

static void dump_dmesg(void)
{
    int len = klogctl(10 /* SYSLOG_ACTION_SIZE_BUFFER */, NULL, 0);
    char *buf;

    if (len <= 0)
        len = 1 << 20;
    buf = malloc(len);
    if (!buf)
        return;
    len = klogctl(3 /* SYSLOG_ACTION_READ_ALL */, buf, len);
    say("[duo2-init] ---- dmesg (%d bytes) ----\r\n", len);
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\n')
            write(port, "\r", 1);
        write(port, &buf[i], 1);
    }
    say("[duo2-init] ---- end dmesg ----\r\n");
    free(buf);
}

/* duo2.idle=N from /proc/cmdline, or the default. */
static long idle_limit(const char *cmdline)
{
    const char *p = strstr(cmdline, "duo2.idle=");

    return p ? strtol(p + 10, NULL, 10) : IDLE_DEFAULT;
}

/* Wait for the gadget's tty to be registered, then make its node. */
static int open_gadget(void)
{
    char devnum[32] = "";
    unsigned maj, min;

    for (int i = 0; i < GADGET_WAIT; i++) {
        int fd = open("/sys/class/tty/ttyGS0/dev", O_RDONLY);

        if (fd >= 0) {
            read(fd, devnum, sizeof(devnum) - 1);
            close(fd);
            break;
        }
        sleep(1);
    }
    if (sscanf(devnum, "%u:%u", &maj, &min) != 2)
        return -1;

    unlink("/dev/ttyGS0");
    if (mknod("/dev/ttyGS0", S_IFCHR | 0600, makedev(maj, min)) < 0)
        return -1;
    return open("/dev/ttyGS0", O_RDWR | O_NOCTTY);
}

static void handle(const char *line)
{
    if (!strcmp(line, "bootloader"))
        restart("host asked", "bootloader");
    else if (!strcmp(line, "reboot"))
        restart("host asked", NULL);
    else if (!strcmp(line, "dmesg"))
        dump_dmesg();
    else if (!strcmp(line, "help") || !line[0])
        say("[duo2-init] commands: bootloader reboot dmesg help\r\n");
    else
        say("[duo2-init] unknown command '%s'\r\n", line);
}

int main(void)
{
    char cmdline[2048] = "";
    char line[128];
    size_t used = 0;
    struct termios t;
    time_t last_input, last_beat;
    long idle;
    int fd;

    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);

    fd = open("/proc/cmdline", O_RDONLY);
    if (fd >= 0) {
        read(fd, cmdline, sizeof(cmdline) - 1);
        close(fd);
    }
    idle = idle_limit(cmdline);

    port = open_gadget();
    if (port < 0)
        restart("no ttyGS0, USB gadget never came up",
                "bootloader");

    if (tcgetattr(port, &t) == 0) {
        cfmakeraw(&t);
        tcsetattr(port, TCSANOW, &t);
    }

    say("\r\n[duo2-init] Luma Duo 2 bring-up init on ttyGS0\r\n");
    dump_file("/proc/version");
    say("\r[duo2-init] idle limit %ld s (0 = none); "
        "send 'help' for commands\r\n", idle);
    /* Without console=ttyGS0 the kernel log is not on this port yet. */
    if (!strstr(cmdline, "console=ttyGS0"))
        dump_dmesg();

    last_input = last_beat = time(NULL);
    for (;;) {
        struct pollfd pfd = { .fd = port, .events = POLLIN };
        time_t now;
        char c;

        if (poll(&pfd, 1, 1000) > 0 && (pfd.revents & POLLIN)) {
            while (read(port, &c, 1) == 1) {
                last_input = time(NULL);
                if (c == '\r' || c == '\n') {
                    line[used] = '\0';
                    if (used)
                        handle(line);
                    used = 0;
                } else if (used < sizeof(line) - 1) {
                    line[used++] = c;
                }
                pfd.revents = 0;
                if (poll(&pfd, 1, 0) <= 0)
                    break;
            }
        }

        now = time(NULL);
        if (idle > 0 && now - last_input >= idle)
            restart("idle limit reached", "bootloader");
        if (now - last_beat >= HEARTBEAT) {
            last_beat = now;
            say("[duo2-init] alive, %lds to auto-bootloader\r\n",
                idle > 0 ? idle - (long)(now - last_input) : -1L);
        }
    }
}
