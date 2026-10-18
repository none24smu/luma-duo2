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
 *
 * While USB is not working there is no way to see any of this from the host,
 * so the same status -- each stage, the USB controller's state, deferred
 * probes and the USB-related kernel log -- is drawn over the boot logo
 * (screen.c), and the enumeration wait is stretched to SCREEN_WAIT so it can
 * be read or photographed before the phone goes back to fastboot.
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
#include <sys/utsname.h>

#include "screen.h"

#define GADGET_WAIT   60
#define LEGACY_WAIT   10
#define SCREEN_WAIT   90
#define IDLE_DEFAULT  120
#define HEARTBEAT     10

static int port = -1;
static time_t t0;

static void status(const char *phase, long left);

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
    char phase[160];

    snprintf(phase, sizeof(phase), "REBOOT %s: %s", arg ? arg : "", why);
    status(phase, 0);
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

/* Read a one-line sysfs/proc value into buf, trimmed; "-" if unreadable. */
static const char *value(const char *path, char *buf, size_t len)
{
    int fd = open(path, O_RDONLY);
    ssize_t n = fd < 0 ? -1 : read(fd, buf, len - 1);

    if (fd >= 0)
        close(fd);
    if (n <= 0)
        return strcpy(buf, "-");
    buf[n] = '\0';
    buf[strcspn(buf, "\n")] = '\0';
    return buf;
}

static int exists(const char *path)
{
    return access(path, F_OK) == 0;
}

/* First UDC registered with the gadget core, or "" if there is none yet. */
static void first_udc(char *name, size_t len)
{
    DIR *d = opendir("/sys/class/udc");
    struct dirent *e;

    name[0] = '\0';
    if (!d)
        return;
    /* Never a dummy_udc: that is a loopback to the phone itself. */
    while ((e = readdir(d)))
        if (e->d_name[0] != '.' && strncmp(e->d_name, "dummy", 5)) {
            snprintf(name, len, "%s", e->d_name);
            break;
        }
    closedir(d);
}

/* Bind the configfs gadget, if one was built, to the first UDC. Retried
 * from the wait loops, since the controller may register late or never. */
static void bind_configfs(void)
{
    char udc[256], cur[256];

    if (!exists("/config/usb_gadget/g1/UDC"))
        return;
    value("/config/usb_gadget/g1/UDC", cur, sizeof(cur));
    if (cur[0] && strcmp(cur, "-"))
        return;
    first_udc(udc, sizeof(udc));
    if (udc[0])
        put("/config/usb_gadget/g1/UDC", udc);
}

/* Build a CDC-ACM gadget in configfs and try to bind it. */
static void configfs_acm(void)
{
    const char *g = "/config/usb_gadget/g1";

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
    bind_configfs();
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

static int interesting(const char *l)
{
    static const char *const keys[] = {
        "usb", "dwc", "phy", "udc", "gadget", "acm", "serial", "defer",
        "fail", "error", "unable", "timeout", "regulator", "init",
    };
    char low[256];
    size_t i;

    for (i = 0; l[i] && i < sizeof(low) - 1; i++)
        low[i] = (l[i] >= 'A' && l[i] <= 'Z') ? l[i] + 32 : l[i];
    low[i] = '\0';
    for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
        if (strstr(low, keys[i]))
            return 1;
    return 0;
}

#define SCREEN_ROWS 60
#define LOG_ROWS    44

/* Draw the current state over the boot logo. Cheap to call when there is no
 * screen: screen_show() does nothing once the probe has found none. */
static void status(const char *phase, long left)
{
    static char rows[SCREEN_ROWS][128];
    static int probed_empty;
    const char *ptr[SCREEN_ROWS];
    char a[64], b[64], c[64], udc[256], path[320];
    char *log = NULL, *tail[LOG_ROWS];
    struct utsname u;
    int n = 0, nt = 0, len;

    static time_t last_draw;

    if (probed_empty)
        return;
    /* Redraws are not free; keep the clock-driven waits honest. */
    if (strncmp(phase, "REBOOT", 6) && last_draw && time(NULL) - last_draw < 3)
        return;
    last_draw = time(NULL);

    uname(&u);
    first_udc(udc, sizeof(udc));
    snprintf(path, sizeof(path), "/sys/class/udc/%s/state", udc);

    snprintf(rows[n++], 128, "LUMA DUO2 BRING-UP   up %lds   %s",
             (long)(time(NULL) - t0), u.release);
    snprintf(rows[n++], 128, "> %s", phase);
    snprintf(rows[n++], 128, "  back to fastboot in %lds", left);
    snprintf(rows[n++], 128, "ttyGS0 %s | udc %s | state %s",
             exists("/sys/class/tty/ttyGS0") ? "yes" : "NO",
             udc[0] ? udc : "NONE", udc[0] ? value(path, a, sizeof(a)) : "-");
    snprintf(rows[n++], 128, "ssusb mode %s | ssusb drv %s | dwc3 drv %s",
             value("/sys/devices/platform/soc/a600000.ssusb/mode", b, sizeof(b)),
             exists("/sys/devices/platform/soc/a600000.ssusb/driver") ? "yes" : "NO",
             exists("/sys/devices/platform/soc/a600000.ssusb/a600000.dwc3/driver")
                 ? "yes" : "NO");
    snprintf(rows[n++], 128, "deferred: %s",
             value("/sys/kernel/debug/devices_deferred", c, sizeof(c)));
    snprintf(rows[n++], 128, "--- kernel log (usb/dwc/phy/udc/defer/fail/error) ---");

    len = klogctl(10 /* SYSLOG_ACTION_SIZE_BUFFER */, NULL, 0);
    if (len > 0 && (log = malloc(len + 1))) {
        len = klogctl(3 /* SYSLOG_ACTION_READ_ALL */, log, len);
        log[len > 0 ? len : 0] = '\0';
        for (char *l = strtok(log, "\n"); l; l = strtok(NULL, "\n")) {
            if (l[0] == '<' && strchr(l, '>'))
                l = strchr(l, '>') + 1;
            if (!interesting(l))
                continue;
            if (nt == LOG_ROWS) {
                memmove(tail, tail + 1, sizeof(tail[0]) * (LOG_ROWS - 1));
                nt--;
            }
            tail[nt++] = l;
        }
    }
    for (int i = 0; i < nt && n < SCREEN_ROWS; i++)
        snprintf(rows[n++], 128, "%s", tail[i]);
    free(log);

    for (int i = 0; i < n; i++)
        ptr[i] = rows[i];
    screen_show(ptr, n);
    if (!screen_count())
        probed_empty = 1;
}

/* Wait for the gadget's tty to be registered, then make its node. */
static int open_gadget(void)
{
    char devnum[32] = "";
    unsigned maj, min;

    time_t start = time(NULL);
    int forced = 0, assembled = 0;

    for (;;) {
        long i = time(NULL) - start;
        int fd;

        if (i >= GADGET_WAIT)
            break;
        fd = open("/sys/class/tty/ttyGS0/dev", O_RDONLY);

        if (fd >= 0) {
            read(fd, devnum, sizeof(devnum) - 1);
            close(fd);
            break;
        }
        status(i < LEGACY_WAIT ? "waiting for ttyGS0 (g_serial)"
                               : "waiting for ttyGS0 (configfs ACM)",
               GADGET_WAIT - i);
        if (i >= 2 && !forced++)
            force_peripheral();
        if (i >= LEGACY_WAIT && !assembled++)
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

/*
 * Commands are matched at the end of the line. When the host opens the port
 * its tty may still have echo on and bounce some of our own output back
 * before it is switched to raw; that arrives as junk ahead of the first
 * command, and must not turn "bootloader" into an unknown command.
 */
static int ends_with(const char *line, const char *cmd)
{
    size_t l = strlen(line), c = strlen(cmd);

    return l >= c && !strcmp(line + l - c, cmd);
}

static void handle(const char *line)
{
    if (ends_with(line, "bootloader"))
        restart("host asked", "bootloader");
    else if (ends_with(line, "reboot"))
        restart("host asked", NULL);
    else if (ends_with(line, "dmesg"))
        dump_dmesg();
    else if (ends_with(line, "help") || !line[0])
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

    t0 = time(NULL);
    /* No devtmpfs: the nodes the status screen needs are made here. */
    mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1));
    mkdir("/sys/kernel/debug", 0755);
    mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);
    status("init started", GADGET_WAIT);

    port = open_gadget();
    if (port < 0)
        restart("no ttyGS0, USB gadget never came up",
                "bootloader");
    {
        int wait = screen_count() ? SCREEN_WAIT : GADGET_WAIT;

        time_t start = time(NULL);

        while (!host_configured()) {
            long i = time(NULL) - start;

            if (i >= wait)
                restart("host never enumerated the gadget", "bootloader");
            bind_configfs();
            status("ttyGS0 up; waiting for the host to enumerate", wait - i);
            sleep(1);
        }
    }
    status("host enumerated the gadget: console live", idle);

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
