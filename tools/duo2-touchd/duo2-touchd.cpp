// duo2-touchd: Surface Duo 2 touch, processed by Microsoft's own heat library.
//
// The Duo 2's digitizer (HID 045E:0C1D on spi0.0) streams raw capacitive heat
// frames, one HID collection per panel. Android turns them into contacts with
// /vendor/lib64/c1/libsurfacetouch_c1.so -- the Duo 2 ("Zeta") build of
// Microsoft's heat processor, with its tuning, panel alignment and hinge
// handling. This daemon loads that same library from the stock vendor image
// and drives it exactly as the stock vendor.surface.touchpen@1.3-service does
// (see docs/touch.md for where each call comes from), then injects the
// contacts through uinput as a standard Linux multitouch screen.
//
// It is an Android (bionic) program: it runs under the stock linker64 with
// the stock runtime libraries, because the library it hosts is one.
//
// Usage: duo2-touchd [--hidraw /dev/hidrawN] [--lib PATH] [--state DIR] [--dump]

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/hidraw.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <set>
#include <vector>

namespace {

bool g_dump = false;
bool g_force_mode = true;

void logf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

// ---------------------------------------------------------------------------
// The library's view of a panel. The stock service keeps two of these, one
// per heat collection: { region, kind, collection } with region 1 / kind 2 for
// the collection holding report 0x0A and region 2 / kind 1 for the one holding
// report 0x3C. The last field identifies the collection.
struct EosHeatDevice {
    uint8_t region;
    uint8_t pad[3];
    uint32_t kind;
    const void *collection;
};
static_assert(sizeof(EosHeatDevice) == 16, "EosHeatDevice layout");

// One contact as the library reports it: 31 bytes, packed.
struct __attribute__((packed)) TouchReport {
    uint16_t unknown0;
    uint16_t contact_id;     // 0xfe: not a contact
    uint8_t state;           // 7: touching; anything else: lifted
    int32_t x, y;
    int32_t width, height;
    uint16_t orientation;    // degrees, 0..180
    uint8_t rest[8];
};
static_assert(sizeof(TouchReport) == 31, "TouchReport layout");

struct AxisRange { int32_t x0, x1, y0, y1; };

// SurfaceHeatProcessorEos's virtual methods, by vtable slot.
enum ProcessorSlot {
    kInitPenTouchMw = 2,
    kProcessIncomingReport = 3,
    kPostDispatchProcessing = 4,
    kOnDeviceAttached = 5,
    kOnStitchingModeChange = 9,
    kOnDisplayChange = 10,
    kGetAxisRange = 12,
    kGetMaxConcurrentPenTouchSlots = 13,
};

struct Processor { void **vtable; };

template <typename Fn>
Fn slot(Processor *p, int index) { return reinterpret_cast<Fn>(p->vtable[index]); }

// ---------------------------------------------------------------------------
// uinput: one touchscreen per panel.
//
// The library reports contacts on one stitched surface spanning both panels
// (x across left panel, hinge gap, right panel), which Android's input stack
// takes as is. Linux compositors map each touch device to one output, so the
// surface is split back into its panels -- at the boundaries the digitizer's
// own metadata gives (each panel's width) -- and each half becomes its own
// device, named for its panel; udev tags it with that panel's output
// (WL_OUTPUT, see config/mobile/duo2-physical's udev rule).
struct Panel {
    explicit Panel(const char *n) : name(n) {}
    const char *name;
    int fd = -1;
    int x_offset = 0, width = 0;
    std::vector<int> slot_contact;   // contact id per slot, -1 if free
    bool dirty = false;
};
Panel g_panels[2] = { Panel("Surface Duo 2 Touchscreen Left"), Panel("Surface Duo 2 Touchscreen Right") };
int g_slots = 10;
int g_contact_panel[0x10000];   // which panel a live contact started on
unsigned long g_contact_reports = 0;

void emit(Panel &p, int type, int code, int value) {
    struct input_event ev = {};
    ev.type = type; ev.code = code; ev.value = value;
    if (write(p.fd, &ev, sizeof ev) != (ssize_t)sizeof ev) logf("uinput write: %s", strerror(errno));
}

void abs_setup(int fd, int code, int min, int max) {
    struct uinput_abs_setup a = {};
    a.code = code; a.absinfo.minimum = min; a.absinfo.maximum = max;
    if (ioctl(fd, UI_ABS_SETUP, &a) < 0) logf("UI_ABS_SETUP %d: %s", code, strerror(errno));
}

bool panel_create(Panel &p, int width, int height, int slots) {
    p.fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (p.fd < 0) { logf("open /dev/uinput: %s", strerror(errno)); return false; }
    p.width = width;
    p.slot_contact.assign(slots, -1);
    ioctl(p.fd, UI_SET_EVBIT, EV_KEY);
    ioctl(p.fd, UI_SET_EVBIT, EV_ABS);
    ioctl(p.fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(p.fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
    // Axes as the stock service configures them (InputEvdev::Attach).
    int diag = 0;
    for (long d2 = (long)width * width + (long)height * height; (long)(diag + 1) * (diag + 1) <= d2;) diag++;
    abs_setup(p.fd, ABS_MT_SLOT, 0, slots - 1);
    abs_setup(p.fd, ABS_MT_TRACKING_ID, 0, 0xffff);
    abs_setup(p.fd, ABS_MT_POSITION_X, 0, width - 1);
    abs_setup(p.fd, ABS_MT_POSITION_Y, 0, height - 1);
    abs_setup(p.fd, ABS_MT_TOUCH_MAJOR, 0, diag);
    abs_setup(p.fd, ABS_MT_TOUCH_MINOR, 0, diag);
    abs_setup(p.fd, ABS_MT_ORIENTATION, -90, 90);
    abs_setup(p.fd, ABS_MT_PRESSURE, 0, 0xffff);
    abs_setup(p.fd, ABS_MT_TOOL_TYPE, 0, MT_TOOL_MAX);
    abs_setup(p.fd, ABS_X, 0, width - 1);
    abs_setup(p.fd, ABS_Y, 0, height - 1);
    struct uinput_setup s = {};
    s.id.bustype = BUS_VIRTUAL; s.id.vendor = 0x045e; s.id.product = 0x0c1d; s.id.version = 1;
    snprintf(s.name, sizeof s.name, "%s", p.name);
    if (ioctl(p.fd, UI_DEV_SETUP, &s) < 0 || ioctl(p.fd, UI_DEV_CREATE) < 0) {
        logf("uinput create %s: %s", p.name, strerror(errno));
        return false;
    }
    return true;
}

// The library's stitched range, split at the panels' own width.
bool panels_create(const AxisRange &r, int panel_width, int slots) {
    int total = r.x1 - r.x0 + 1, height = r.y1 - r.y0 + 1;
    if (panel_width <= 0 || panel_width * 2 > total) panel_width = total / 2;
    g_slots = slots;
    for (int &c : g_contact_panel) c = -1;
    g_panels[0].x_offset = r.x0;
    g_panels[1].x_offset = r.x0 + total - panel_width;
    for (Panel &p : g_panels)
        if (!panel_create(p, panel_width, height, slots)) return false;
    logf("touchscreens: %d x %d each, right panel from x %d (stitched range %d..%d, %d slots)",
         panel_width, height, g_panels[1].x_offset, r.x0, r.x1, slots);
    return true;
}

// Lift every contact still down before the devices go away: a compositor that
// sees a touchscreen vanish mid-touch may never end the touch sequence, and
// the client holding it (Phosh's lock screen carousel, mid-swipe) stays stuck.
void panels_lift_all() {
    for (Panel &p : g_panels) {
        if (p.fd < 0) continue;
        bool any = false;
        for (int k = 0; k < (int)p.slot_contact.size(); k++) {
            if (p.slot_contact[k] < 0) continue;
            p.slot_contact[k] = -1;
            emit(p, EV_ABS, ABS_MT_SLOT, k);
            emit(p, EV_ABS, ABS_MT_TRACKING_ID, -1);
            any = true;
        }
        if (any) {
            emit(p, EV_KEY, BTN_TOUCH, 0);
            emit(p, EV_SYN, SYN_REPORT, 0);
        }
    }
    for (int &c : g_contact_panel) c = -1;
}

void panels_destroy() {
    panels_lift_all();
    usleep(50 * 1000);   // let the compositor read the lifts first
    for (Panel &p : g_panels)
        if (p.fd >= 0) { ioctl(p.fd, UI_DEV_DESTROY); close(p.fd); p.fd = -1; }
}

// Contacts into evdev, as InputEvdev::TouchReports does, each on the panel
// its touch began on (a finger that slides into the hinge gap stays put).
void touch_reports(const TouchReport *reports, unsigned count) {
    g_contact_reports += count;
    for (unsigned i = 0; i < count; i++) {
        const TouchReport &t = reports[i];
        if (g_dump)
            logf("contact id=%u state=%u x=%d y=%d w=%d h=%d o=%u", t.contact_id, t.state, t.x, t.y,
                 t.width, t.height, t.orientation);
        if (t.contact_id == 0xfe) continue;
        int &owner = g_contact_panel[t.contact_id];
        if (owner < 0 && t.state == 7)
            owner = t.x >= g_panels[1].x_offset - (g_panels[1].x_offset - g_panels[0].x_offset - g_panels[0].width) / 2;
        if (owner < 0) continue;
        Panel &p = g_panels[owner];
        int s = -1, free_slot = -1;
        for (int k = 0; k < g_slots; k++) {
            if (p.slot_contact[k] == t.contact_id) { s = k; break; }
            if (free_slot < 0 && p.slot_contact[k] < 0) free_slot = k;
        }
        p.dirty = true;
        if (t.state == 7) {
            if (s < 0) s = free_slot;
            if (s < 0) { logf("%s: all touch slots are taken", p.name); continue; }
            int x = t.x - p.x_offset;
            x = x < 0 ? 0 : x >= p.width ? p.width - 1 : x;
            p.slot_contact[s] = t.contact_id;
            emit(p, EV_ABS, ABS_MT_SLOT, s);
            emit(p, EV_ABS, ABS_MT_TRACKING_ID, t.contact_id);
            emit(p, EV_ABS, ABS_MT_POSITION_X, x);
            emit(p, EV_ABS, ABS_MT_POSITION_Y, t.y);
            emit(p, EV_ABS, ABS_MT_TOOL_TYPE, MT_TOOL_FINGER);
            emit(p, EV_ABS, ABS_MT_PRESSURE, 0xffff);
            emit(p, EV_ABS, ABS_MT_TOUCH_MAJOR, t.width > t.height ? t.width : t.height);
            emit(p, EV_ABS, ABS_MT_TOUCH_MINOR, t.width > t.height ? t.height : t.width);
            emit(p, EV_ABS, ABS_MT_ORIENTATION, t.orientation > 90 ? t.orientation - 180 : t.orientation);
            if (s == 0) {   // single-touch emulation follows slot 0
                emit(p, EV_ABS, ABS_X, x);
                emit(p, EV_ABS, ABS_Y, t.y);
            }
        } else {
            owner = -1;
            if (s < 0) continue;
            p.slot_contact[s] = -1;
            emit(p, EV_ABS, ABS_MT_SLOT, s);
            emit(p, EV_ABS, ABS_MT_PRESSURE, 0);
            emit(p, EV_ABS, ABS_MT_TRACKING_ID, -1);
        }
    }
    for (Panel &p : g_panels) {
        if (!p.dirty) continue;
        bool any = false;
        for (int c : p.slot_contact) any |= c >= 0;
        emit(p, EV_KEY, BTN_TOUCH, any ? 1 : 0);
        emit(p, EV_SYN, SYN_REPORT, 0);
        p.dirty = false;
    }
}

// Each panel's width, from the digitizer's metadata feature report (report 6,
// Digitizer usage 0x63): rows, columns, width, height as uint32 after a
// 14-byte header, in the library's 0.01 mm units (85.21 x 120.20 mm here).
int panel_width_from_metadata(int fd) {
    uint8_t buf[120] = { 0x06 };
    int n = ioctl(fd, HIDIOCGFEATURE(sizeof buf), buf);
    if (n < 30) { logf("metadata report: %s", n < 0 ? strerror(errno) : "short"); return 0; }
    uint32_t dims[4];
    memcpy(dims, buf + 14, sizeof dims);
    if (dims[0] == 0 || dims[0] > 200 || dims[1] == 0 || dims[1] > 200 || dims[2] < 1000) {
        logf("metadata report: unexpected layout"); return 0;
    }
    logf("digitizer: %u x %u sensors per panel, %u.%02u x %u.%02u mm", dims[0], dims[1],
         dims[2] / 100, dims[2] % 100, dims[3] / 100, dims[3] % 100);
    return (int)dims[2];
}

// ---------------------------------------------------------------------------
// The host side of the library: IEosHeatService. Slots as the library calls
// them (HeatAdaptorEos): 2 SetAngleSensitivity, 3 SendMessageToTouchFw,
// 4 SendPenReports, 5 SendTouchReports, 6 SendHidReportsToTPAgent. Slots
// beyond are not called by this library; they are answered harmlessly.
int g_hidraw = -1;

void svc_noop(void *) {}
void svc_set_angle_sensitivity(void *, float) {}
// HidReport { uint32 length; uint8 *data } is passed by value in two registers.
// The stock service writes it to hidraw and returns *true on failure*.
bool svc_send_message_to_touch_fw(void *, uint32_t length, const uint8_t *data, const EosHeatDevice *) {
    if (g_dump) {
        char hex[3 * 48 + 1] = {}; int o = 0;
        for (uint32_t k = 0; k < length && k < 48; k++) o += snprintf(hex + o, sizeof hex - o, "%02x ", data[k]);
        logf("to touch fw: %u bytes: %s", length, hex);
    }
    ssize_t n = write(g_hidraw, data, length);
    if (n != (ssize_t)length) logf("hidraw write (%u bytes): %s", length, strerror(errno));
    return n != (ssize_t)length;
}
void svc_send_pen_reports(void *, const void *, uint32_t) {}
void svc_send_touch_reports(void *, const TouchReport *reports, uint32_t count) { touch_reports(reports, count); }
long svc_unused(void *) { return 0; }

void *g_service_vtable[16] = {
    (void *)svc_noop, (void *)svc_noop,
    (void *)svc_set_angle_sensitivity,
    (void *)svc_send_message_to_touch_fw,
    (void *)svc_send_pen_reports,
    (void *)svc_send_touch_reports,
    (void *)svc_unused, (void *)svc_unused, (void *)svc_unused, (void *)svc_unused,
    (void *)svc_unused, (void *)svc_unused, (void *)svc_unused, (void *)svc_unused,
    (void *)svc_unused, (void *)svc_unused,
};
struct Service { void **vtable; } g_service = { g_service_vtable };

// ---------------------------------------------------------------------------
// Which panel a report belongs to: the report IDs inside each of the two
// Digitizer "capacitive heat map" (0x0D/0x0F) application collections.
struct Collections { std::set<int> panel[2]; };

Collections parse_descriptor(const uint8_t *d, int n) {
    Collections c;
    int usage_page = 0, depth = 0, heat = -1, heat_seen = 0, last_usage = -1;
    for (int i = 0; i < n;) {
        uint8_t b = d[i];
        int size = b & 3; if (size == 3) size = 4;
        uint32_t v = 0;
        for (int k = 0; k < size && i + 1 + k < n; k++) v |= (uint32_t)d[i + 1 + k] << (8 * k);
        switch (b & 0xfc) {
        case 0x04: usage_page = v; break;
        case 0x08: last_usage = v; break;
        case 0xa0:   // Collection
            if (depth == 0 && usage_page == 0x0d && last_usage == 0x0f) heat = heat_seen++;
            depth++; break;
        case 0xc0:   // End Collection
            if (--depth == 0) heat = -1;
            break;
        case 0x84:   // Report ID
            if (heat >= 0 && heat < 2) c.panel[heat].insert(v);
            break;
        }
        i += 1 + size;
    }
    return c;
}

const char kSpiReady[] = "/sys/bus/spi/devices/spi0.0/ready";

bool wait_ready(int timeout_ms) {
    for (int waited = 0; waited <= timeout_ms; waited += 50) {
        char s[16] = {};
        int fd = open(kSpiReady, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            ssize_t n = read(fd, s, sizeof s - 1);
            close(fd);
            if (n > 0 && !strncmp(s, "ready", 5)) return true;
        }
        usleep(50 * 1000);
    }
    return false;
}

// Bring-up control: a FIFO taking lines "tap PANEL FX FY" (PANEL l or r,
// FX/FY as fractions of the panel) to test the input stack hands-off.
const char kControl[] = "/run/duo2-touchd.ctl";
int g_control = -1;

void scripted_tap(int panel, double fx, double fy) {
    Panel &p = g_panels[panel];
    TouchReport t = {};
    t.contact_id = 0x7f01; t.state = 7; t.width = 900; t.height = 900; t.orientation = 90;
    t.x = p.x_offset + (int)(fx * (p.width - 1));
    t.y = (int)(fy * 12019);
    for (int i = 0; i < 4; i++) { touch_reports(&t, 1); usleep(10000); }
    t.state = 0;
    touch_reports(&t, 1);
    usleep(120000);
}

void control_open() {
    unlink(kControl);
    if (mkfifo(kControl, 0600) < 0) { logf("%s: %s", kControl, strerror(errno)); return; }
    g_control = open(kControl, O_RDWR | O_NONBLOCK | O_CLOEXEC);
}

void control_read() {
    static char line[256]; static size_t len = 0;
    char c;
    while (read(g_control, &c, 1) == 1) {
        if (c != '\n') { if (len < sizeof line - 1) line[len++] = c; continue; }
        line[len] = 0; len = 0;
        char panel; double fx, fy;
        if (sscanf(line, "tap %c %lf %lf", &panel, &fx, &fy) == 3 && (panel == 'l' || panel == 'r')) {
            scripted_tap(panel == 'r', fx, fy);
            logf("scripted tap %c %.2f %.2f", panel, fx, fy);
        } else if (!strcmp(line, "lift")) {
            panels_lift_all();
            logf("lifted all contacts");
        } else {
            logf("control: unknown command '%s'", line);
        }
    }
}

volatile sig_atomic_t g_stop = 0;
volatile sig_atomic_t g_swipe = 0;   // 1: full swipe up (SIGUSR1), 2: partial (SIGUSR2)
void on_signal(int) { g_stop = 1; }
void on_swipe_signal(int sig) { g_swipe = sig == SIGUSR2 ? 2 : 1; }


// A scripted swipe up the middle of the right panel through the running
// daemon's own devices -- SIGUSR1 a full one, SIGUSR2 a short one -- to test
// the input stack exactly as touches take it, without hands on the device.
void scripted_swipe(int steps) {
    TouchReport t = {};
    t.contact_id = 0x7f00; t.state = 7; t.width = 1500; t.height = 1500; t.orientation = 90;
    t.x = g_panels[1].x_offset + g_panels[1].width / 2;
    for (int step = 0; step <= steps; step++) {
        t.y = 11900 - step * 200;
        touch_reports(&t, 1);
        usleep(16000);
    }
    t.state = 0;
    touch_reports(&t, 1);
    logf("scripted swipe sent (%d steps)", steps);
}

}  // namespace

int main(int argc, char **argv) {
    const char *hidraw = "/dev/hidraw0";
    const char *lib = "/vendor/lib64/c1/libsurfacetouch_c1.so";
    const char *state = "/var/lib/duo2-touchd";
    bool selftest = false;
    int selftest_x = 13194;   // middle of the right panel
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hidraw") && i + 1 < argc) hidraw = argv[++i];
        else if (!strcmp(argv[i], "--lib") && i + 1 < argc) lib = argv[++i];
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) state = argv[++i];
        else if (!strcmp(argv[i], "--dump")) g_dump = true;
        else if (!strcmp(argv[i], "--no-force-mode")) g_force_mode = false;
        else if (!strcmp(argv[i], "--selftest")) selftest = true;
        else if (!strcmp(argv[i], "--selftest-x") && i + 1 < argc) { selftest = true; selftest_x = atoi(argv[++i]); }
        else { logf("usage: %s [--hidraw DEV] [--lib PATH] [--state DIR] [--dump]", argv[0]); return 2; }
    }
    if (selftest) {
        // A scripted swipe up a panel (default: the middle of the right one), through the
        // same contact-to-evdev path the library's reports take; for testing
        // the input stack without hands on the device. Ranges are the ones
        // the library reports for the Duo 2.
        AxisRange r = { 0, 17455, 0, 12019 };
        if (!panels_create(r, 8521, 11)) return 1;
        sleep(2);   // let the compositor open the new device
        TouchReport t = {};
        t.contact_id = 1; t.state = 7; t.x = selftest_x; t.width = 1500; t.height = 1500; t.orientation = 90;
        for (int step = 0; step <= 30; step++) {
            t.y = 11900 - step * 200;
            touch_reports(&t, 1);
            usleep(16000);
        }
        t.state = 0;
        touch_reports(&t, 1);
        sleep(1);
        panels_destroy();
        return 0;
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGUSR1, on_swipe_signal);
    signal(SIGUSR2, on_swipe_signal);
    mkdir(state, 0700);

    g_hidraw = open(hidraw, O_RDWR | O_CLOEXEC);
    if (g_hidraw < 0) { logf("open %s: %s", hidraw, strerror(errno)); return 1; }
    struct hidraw_devinfo info = {};
    ioctl(g_hidraw, HIDIOCGRAWINFO, &info);
    if ((uint16_t)info.vendor != 0x045e || (uint16_t)info.product != 0x0c1d) {
        logf("%s is %04x:%04x, not the Duo 2 digitizer (045e:0c1d)", hidraw,
             (uint16_t)info.vendor, (uint16_t)info.product);
        return 1;
    }
    // Opening hidraw wakes the digitizer; spi-hid reports it usable through
    // its "ready" attribute, and the stock service waits for that before it
    // starts the library (HidrawDevice::startPollingOnReadyFile). Writes
    // before then fail with ENODEV.
    if (!wait_ready(10000)) { logf("%s never became ready", kSpiReady); return 1; }
    struct hidraw_report_descriptor desc = {};
    ioctl(g_hidraw, HIDIOCGRDESCSIZE, &desc.size);
    ioctl(g_hidraw, HIDIOCGRDESC, &desc);
    Collections col = parse_descriptor(desc.value, desc.size);
    if (col.panel[0].count(0x0a) == 0 || col.panel[1].count(0x3c) == 0) {
        logf("descriptor: the two heat collections are not where the stock service expects them");
        return 1;
    }

    void *h = dlopen(lib, RTLD_NOW);
    if (!h) { logf("dlopen %s: %s", lib, dlerror()); return 1; }
    auto create = reinterpret_cast<Processor *(*)()>(dlsym(h, "CreateHeatProcessorInstance"));
    if (!create) { logf("no CreateHeatProcessorInstance in %s", lib); return 1; }
    Processor *proc = create();
    if (!proc) { logf("CreateHeatProcessorInstance failed"); return 1; }

    // The two panels, as the stock service sets them up.
    static EosHeatDevice dev_a = { 1, {}, 2, &col.panel[0] };
    static EosHeatDevice dev_b = { 2, {}, 1, &col.panel[1] };

    slot<void (*)(Processor *, const EosHeatDevice *, const char *, Service *, uint16_t)>(proc, kInitPenTouchMw)(
        proc, &dev_a, state, &g_service, 0x0c1d);
    slot<void (*)(Processor *, const EosHeatDevice *)>(proc, kOnDeviceAttached)(proc, &dev_b);
    // Stitching (one surface across both panels) is Android's spanned-app
    // mode; it needs a frame from each panel every scan cycle and drops the
    // rest ("ParserInvalidStitchingCycleNumber"). Each panel is its own
    // touchscreen here, so it stays off, as the stock service has it unless
    // an app spans both screens.
    slot<void (*)(Processor *, bool)>(proc, kOnStitchingModeChange)(proc, false);
    AxisRange range = slot<AxisRange (*)(Processor *)>(proc, kGetAxisRange)(proc);
    int slots = (uint8_t)slot<uint16_t (*)(Processor *)>(proc, kGetMaxConcurrentPenTouchSlots)(proc) + 1;
    if (!panels_create(range, panel_width_from_metadata(g_hidraw), slots)) return 1;

    // Both panels on: what the stock service does for BOTH_DISPLAYS_ON.
    slot<void (*)(Processor *, const EosHeatDevice *, bool)>(proc, kOnDisplayChange)(proc, &dev_a, true);
    slot<void (*)(Processor *, const EosHeatDevice *, bool)>(proc, kOnDisplayChange)(proc, &dev_b, true);
    // Heat mode and display state. The library's own configuration leaves
    // the digitizer in its single-point fallback (report 0x40); on Android
    // the stock service's surroundings put it in heat mode (feature report 5,
    // vendor usage 0xC8 = 1) and report which panels are on (output report
    // 0x38: bit 0 left, bit 1 right). Without both, no heat frames arrive.
    if (g_force_mode) {
        const uint8_t mode[2] = { 0x05, 0x01 };
        if (ioctl(g_hidraw, HIDIOCSFEATURE(sizeof mode), mode) < 0) logf("set heat mode: %s", strerror(errno));
        const uint8_t on[2] = { 0x38, 0x03 };
        if (write(g_hidraw, on, sizeof on) != (ssize_t)sizeof on) logf("display state: %s", strerror(errno));
    }
    control_open();
    logf("running: %s through %s", hidraw, lib);

    static uint8_t buf[16384];
    unsigned long frames = 0;
    while (!g_stop) {
        if (g_swipe) { scripted_swipe(g_swipe == 2 ? 8 : 30); g_swipe = 0; }
        {
            static time_t last_stats = time(nullptr);
            static unsigned long last_frames = 0, last_contacts = 0;
            if (time(nullptr) - last_stats >= 30) {
                if (frames != last_frames || g_contact_reports != last_contacts)
                    logf("last 30 s: %lu panel reports, %lu contact reports",
                         frames - last_frames, g_contact_reports - last_contacts);
                last_frames = frames; last_contacts = g_contact_reports; last_stats = time(nullptr);
            }
        }
        struct pollfd p[2] = { { g_hidraw, POLLIN, 0 }, { g_control, POLLIN, 0 } };
        if (poll(p, g_control >= 0 ? 2 : 1, 1000) <= 0) continue;
        if (g_control >= 0 && (p[1].revents & POLLIN)) control_read();
        if (!(p[0].revents & POLLIN)) continue;
        ssize_t n = read(g_hidraw, buf, sizeof buf);
        if (n <= 0) { if (errno == EINTR) continue; logf("hidraw read: %s", strerror(errno)); break; }
        if (g_dump) {
            static unsigned counts[256];
            static time_t last = time(nullptr);
            counts[buf[0]]++;
            if (time(nullptr) - last >= 5) {
                char line[512]; int o = 0;
                for (int r = 0; r < 256; r++)
                    if (counts[r]) { o += snprintf(line + o, sizeof line - o, " %02x:%u", r, counts[r]); counts[r] = 0; }
                logf("reports in the last 5 s:%s", line);
                last = time(nullptr);
            }
        }
        const EosHeatDevice *dev = nullptr;
        if (buf[0] == 0xfe && n > 1) dev = buf[1] == 1 ? &dev_a : buf[1] == 2 ? &dev_b : nullptr;
        else if (col.panel[0].count(buf[0])) dev = &dev_a;
        else if (col.panel[1].count(buf[0])) dev = &dev_b;
        if (!dev) continue;
        slot<void (*)(Processor *, const EosHeatDevice *, uint32_t, const uint8_t *)>(proc, kProcessIncomingReport)(
            proc, dev, (uint32_t)n, buf);
        // As the stock service: after every report but heartbeats.
        if (buf[0] != 0xfe)
            slot<void (*)(Processor *, const EosHeatDevice *)>(proc, kPostDispatchProcessing)(proc, dev);
        ++frames;
    }
    logf("stopping");
    if (g_control >= 0) { close(g_control); unlink(kControl); }
    panels_destroy();
    return 0;
}
