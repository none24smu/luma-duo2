/* duo2-kmstest: light every connected panel with plain KMS.
 *
 * The first-light test for the Duo 2's displays. No libdrm, no GPU: dumb
 * buffers and legacy SETCRTC through the kernel's DRM ioctls, so the only
 * thing under test is the display driver itself (msm_drm/SDE on Microsoft's
 * 5.4 kernel). Each connected connector gets its first mode and a frame of
 * vertical colour bars with the connector name's index as a white block
 * count, held for the given number of seconds.
 *
 * Usage: duo2-kmstest [seconds] [--x0]      (default 15)
 *   --x0   leave the unused top byte of each XRGB8888 pixel at 0, as most
 *          renderers do, instead of 0xff -- shows whether the display
 *          pipeline treats it as alpha.
 *   --last take the highest-numbered free CRTC instead of the lowest, as
 *          Weston does -- shows whether only some CRTCs reach the panels.
 */
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define MAX 32

static int io(int fd, unsigned long req, void *arg)
{
    int r;

    do
        r = ioctl(fd, req, arg);
    while (r < 0 && (errno == EINTR || errno == EAGAIN));
    return r;
}

static uint32_t xmask = 0xffffffff;
static int pick_last;

static void bars(uint32_t *px, uint32_t w, uint32_t h, uint32_t pitch, int idx)
{
    static const uint32_t colour[] = {
        0xffffffff, 0xffffff00, 0xff00ffff, 0xff00ff00,
        0xffff00ff, 0xffff0000, 0xff0000ff, 0xff000000,
    };

    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++)
            px[y * (pitch / 4) + x] = colour[x * 8 / w] & xmask;
    /* idx+1 white squares down the left edge, to tell the screens apart */
    for (int b = 0; b <= idx; b++)
        for (uint32_t y = 100 + b * 160; y < 100 + b * 160 + 120 && y < h; y++)
            for (uint32_t x = 60; x < 180 && x < w; x++)
                px[y * (pitch / 4) + x] = 0xffffffff & xmask;
}

int main(int argc, char **argv)
{
    int hold = argc > 1 ? atoi(argv[1]) : 15;
    uint32_t conn_ids[MAX], crtc_ids[MAX], enc_ids[MAX], used_crtcs = 0;
    struct drm_mode_card_res res = {0};
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC), lit = 0;

    for (int a = 1; a < argc; a++)
        if (!strcmp(argv[a], "--x0"))
            xmask = 0x00ffffff;
        else if (!strcmp(argv[a], "--last"))
            pick_last = 1;
    if (fd < 0) { perror("open /dev/dri/card0"); return 1; }
    if (io(fd, DRM_IOCTL_SET_MASTER, NULL))
        perror("SET_MASTER (continuing)");

    if (io(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("GETRESOURCES"); return 1; }
    if (res.count_connectors > MAX) res.count_connectors = MAX;
    if (res.count_crtcs > MAX) res.count_crtcs = MAX;
    if (res.count_encoders > MAX) res.count_encoders = MAX;
    res.connector_id_ptr = (uintptr_t)conn_ids;
    res.crtc_id_ptr = (uintptr_t)crtc_ids;
    res.encoder_id_ptr = (uintptr_t)enc_ids;
    res.count_fbs = 0;
    if (io(fd, DRM_IOCTL_MODE_GETRESOURCES, &res)) { perror("GETRESOURCES"); return 1; }
    printf("%u connectors, %u crtcs, %u encoders\n",
           res.count_connectors, res.count_crtcs, res.count_encoders);

    for (uint32_t i = 0; i < res.count_connectors; i++) {
        struct drm_mode_get_connector c = { .connector_id = conn_ids[i] };
        struct drm_mode_modeinfo modes[16];
        uint32_t encs[MAX];
        struct drm_mode_get_encoder e = {0};
        struct drm_mode_create_dumb db = {0};
        struct drm_mode_fb_cmd fb = {0};
        struct drm_mode_map_dumb map = {0};
        struct drm_mode_crtc set = {0};
        uint32_t crtc = 0;
        void *mem;

        if (io(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) continue;
        if (c.connection != 1 || !c.count_modes) {
            printf("connector %u: not connected\n", c.connector_id);
            continue;
        }
        if (c.count_modes > 16) c.count_modes = 16;
        if (c.count_encoders > MAX) c.count_encoders = MAX;
        c.modes_ptr = (uintptr_t)modes;
        c.encoders_ptr = (uintptr_t)encs;
        c.count_props = 0;
        if (io(fd, DRM_IOCTL_MODE_GETCONNECTOR, &c)) { perror("GETCONNECTOR"); continue; }
        if (c.count_modes > 16) c.count_modes = 16;
        for (uint32_t m = 0; m < c.count_modes; m++)
            printf("connector %u mode %u: \"%s\" %ux%u@%u clock=%u flags=0x%x type=0x%x\n",
                   c.connector_id, m, modes[m].name, modes[m].hdisplay,
                   modes[m].vdisplay, modes[m].vrefresh, modes[m].clock,
                   modes[m].flags, modes[m].type);

        /* First encoder, then the first CRTC it can drive that is free. */
        e.encoder_id = c.encoder_id ? c.encoder_id : encs[0];
        if (io(fd, DRM_IOCTL_MODE_GETENCODER, &e)) { perror("GETENCODER"); continue; }
        for (uint32_t n = 0; n < res.count_crtcs; n++) {
            uint32_t k = pick_last ? res.count_crtcs - 1 - n : n;

            if ((e.possible_crtcs & (1u << k)) && !(used_crtcs & (1u << k))) {
                crtc = crtc_ids[k];
                used_crtcs |= 1u << k;
                break;
            }
        }
        if (!crtc) { printf("connector %u: no free crtc\n", c.connector_id); continue; }

        db.width = modes[0].hdisplay;
        db.height = modes[0].vdisplay;
        db.bpp = 32;
        if (io(fd, DRM_IOCTL_MODE_CREATE_DUMB, &db)) { perror("CREATE_DUMB"); continue; }
        fb.width = db.width; fb.height = db.height;
        fb.bpp = 32; fb.depth = 24; fb.pitch = db.pitch; fb.handle = db.handle;
        if (io(fd, DRM_IOCTL_MODE_ADDFB, &fb)) { perror("ADDFB"); continue; }
        map.handle = db.handle;
        if (io(fd, DRM_IOCTL_MODE_MAP_DUMB, &map)) { perror("MAP_DUMB"); continue; }
        mem = mmap(NULL, db.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map.offset);
        if (mem == MAP_FAILED) { perror("mmap"); continue; }
        bars(mem, db.width, db.height, db.pitch, lit);

        set.crtc_id = crtc;
        set.fb_id = fb.fb_id;
        set.set_connectors_ptr = (uintptr_t)&c.connector_id;
        set.count_connectors = 1;
        set.mode = modes[0];
        set.mode_valid = 1;
        if (io(fd, DRM_IOCTL_MODE_SETCRTC, &set)) {
            printf("connector %u -> crtc %u: SETCRTC failed: %s\n",
                   c.connector_id, crtc, strerror(errno));
            continue;
        }
        printf("connector %u -> crtc %u: %ux%u@%u \"%s\" lit (%d block%s)\n",
               c.connector_id, crtc, modes[0].hdisplay, modes[0].vdisplay,
               modes[0].vrefresh, modes[0].name, lit + 1, lit ? "s" : "");
        lit++;
    }
    printf("%d panel(s) lit; holding %d s\n", lit, hold);
    fflush(stdout);
    sleep(hold);
    return lit ? 0 : 1;
}
