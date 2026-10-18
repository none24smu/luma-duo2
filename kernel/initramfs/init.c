/* Bring-up init for the Surface Duo 2.
 *
 * Two jobs: talk over the USB serial gadget (/dev/ttyGS0, ttyACM0 on the
 * host), and always get the phone back to fastboot without anyone touching
 * it. The Duo 2 has no reset pin and a hung kernel leaves the logo on screen
 * forever, so every way out of this program ends in a reboot to the
 * bootloader:
 *
 *   - the host sends "bootloader" over the port          -> fastboot now
 *   - ttyGS0 never appears, or the host never enumerates -> fastboot after
 *     the gadget (UDC state never "configured")             GADGET_WAIT s
 *   - nothing arrives from the host for duo2.idle=N s    -> fastboot
 *     (default IDLE_DEFAULT; 0 disables)
 *
 * The enumeration check matters because ttyGS0 exists as soon as the gadget
 * function does, whether or not USB works: waiting for the tty alone sent a
 * broken-USB boot to the long idle timer instead of straight home.
 *
 * Every write to the port is non-blocking and dropped if it cannot go out.
 * A gadget tty with no host reading it fills its buffer and then blocks the
 * writer forever, which would wedge this program -- and with it every way
 * back to fastboot -- on a single log line.
 *
 * Panics are covered by the kernel side: qcom_reboot_reason.panic_reason=
 * bootloader and download_mode=0 on the command line.
 *
 * Commands, one per line: bootloader, reboot, dmesg, help. Anything received
 * resets the idle timer.
 *
 * There is no devtmpfs in the vendor kernel, so /dev/ttyGS0 is created here
 * from the number sysfs reports rather than trusted from the initramfs.
 *
 * ttyGS0 comes from one of two places. A kernel with the legacy g_serial
 * gadget built in (our msm-5.4 build) raises it unaided. Microsoft's stock
 * kernel has only configfs, so if ttyGS0 has not appeared after
 * LEGACY_WAIT seconds, an ACM gadget is assembled in configfs here, with
 * g_serial's USB ID so the host tooling does not care which kernel it is.
 */
#include <dirent.h>
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
#define LEGACY_WAIT   10
#define IDLE_DEFAULT  120
#define HEARTBEAT     10

static int port = -1;

/* Best effort: anything the gadget cannot take right now is dropped. */
static void out(const char *buf, size_t n)
{
    if (port < 0) {
        write(2, buf, n);
        return;
    }
    while (n > 0) {
        ssize_t w = write(port, buf, n);

        if (w <= 0)
            return;
        buf += w;
        n -= w;
    }
}

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
    out(buf, n);
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
        out(buf, n);
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
    for (int i = 0, start = 0; i < len; i++)
        if (buf[i] == '\n') {
            out(buf + start, i - start);
            out("\r\n", 2);
            start = i + 1;
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

static void put(const char *path, const char *val)
{
    int fd = open(path, O_WRONLY);

    if (fd >= 0) {
        write(fd, val, strlen(val));
        close(fd);
    }
}

/* First UDC registered with the gadget core, or "" if there is none yet. */
static void first_udc(char *name, size_t len)
{
    DIR *d = opendir("/sys/class/udc");
    struct dirent *e;

    name[0] = '\0';
    if (!d)
        return;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.') {
            snprintf(name, len, "%s", e->d_name);
            break;
        }
    closedir(d);
}

/* Build a CDC-ACM gadget in configfs and bind it to the first UDC. */
static void configfs_acm(void)
{
    const char *g = "/config/usb_gadget/g1";
    char udc[256];

    mkdir("/config", 0755);
    mount("configfs", "/config", "configfs", 0, NULL);
    mkdir(g, 0755);
    put("/config/usb_gadget/g1/idVendor", "0x0525");
    put("/config/usb_gadget/g1/idProduct", "0xa4a7");
    mkdir("/config/usb_gadget/g1/strings/0x409", 0755);
    put("/config/usb_gadget/g1/strings/0x409/manufacturer", "Luma");
    put("/config/usb_gadget/g1/strings/0x409/product", "Duo 2 bring-up console");
    mkdir("/config/usb_gadget/g1/functions/acm.usb0", 0755);
    mkdir("/config/usb_gadget/g1/configs/c.1", 0755);
    symlink("/config/usb_gadget/g1/functions/acm.usb0",
            "/config/usb_gadget/g1/configs/c.1/acm.usb0");
    for (int i = 0; i < GADGET_WAIT; i++) {
        first_udc(udc, sizeof(udc));
        if (udc[0]) {
            put("/config/usb_gadget/g1/UDC", udc);
            return;
        }
        sleep(1);
    }
}

/*
 * dwc3-msm leaves the controller in mode "none" when it expects a role from
 * the Type-C stack (usb-role-switch in the DT). Its sysfs mode attribute
 * overrides that, so if the DT fix did not take, force peripheral here.
 */
static void force_peripheral(void)
{
    const char *mode = "/sys/devices/platform/soc/a600000.ssusb/mode";
    char cur[32] = "";
    int fd = open(mode, O_RDONLY);

    if (fd < 0)
        return;
    read(fd, cur, sizeof(cur) - 1);
    close(fd);
    if (strncmp(cur, "peripheral", 10))
        put(mode, "peripheral");
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
        if (i == 2)
            force_peripheral();
        if (i == LEGACY_WAIT)
            configfs_acm();
        sleep(1);
    }
    if (sscanf(devnum, "%u:%u", &maj, &min) != 2)
        return -1;

    unlink("/dev/ttyGS0");
    if (mknod("/dev/ttyGS0", S_IFCHR | 0600, makedev(maj, min)) < 0)
        return -1;
    return open("/dev/ttyGS0", O_RDWR | O_NOCTTY | O_NONBLOCK);
}

/* True once some UDC reports that the host has configured the gadget. */
static int host_configured(void)
{
    char udc[256], path[320], state[32] = "";
    int fd;

    first_udc(udc, sizeof(udc));
    if (!udc[0])
        return 0;
    snprintf(path, sizeof(path), "/sys/class/udc/%s/state", udc);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    read(fd, state, sizeof(state) - 1);
    close(fd);
    return !strncmp(state, "configured", 10);
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
    for (int i = 0; !host_configured(); i++) {
        if (i >= GADGET_WAIT)
            restart("host never enumerated the gadget", "bootloader");
        sleep(1);
    }

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
