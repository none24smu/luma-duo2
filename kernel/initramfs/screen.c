/* Status text on the Duo 2's screens, drawn into the bootloader's splash.
 *
 * During bring-up the only output the phone has is the logo the ABL left on
 * screen: no display driver is loaded, so the display controller (MDSS) just
 * keeps scanning out the splash buffer. Whatever is written into that buffer
 * shows up. This finds the buffer and writes text into it.
 *
 * Nothing about the layout is assumed. The ABL programmed the controller's
 * source pipes (SSPPs) to fetch the splash, so their registers say where each
 * buffer is, how big, the line stride and the bytes per pixel. Every pipe
 * whose address falls inside the splash region gets the text, which covers
 * one buffer per screen as well as one shared buffer.
 *
 * Needs /dev/mem with CONFIG_STRICT_DEVMEM off (patch 0003): the splash
 * region is reserved RAM, which strict mode refuses to map.
 *
 * Register offsets are from Microsoft's techpack/display sde_hw_sspp.c; the
 * MDP base and pipe offsets from the stock DT (qcom,mdss_mdp@ae00000).
 */
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "font8x16.h"   /* generated from the kernel's lib/fonts/font_8x16.c */
#include "screen.h"

#define MDP_BASE        0x0ae00000UL
#define SPLASH_BASE     0xe1000000UL
#define SPLASH_SIZE     0x02300000UL

#define SSPP_SRC_SIZE           0x00
#define SSPP_SRC0_ADDR          0x14
#define SSPP_SRC_YSTRIDE0       0x24
#define SSPP_SRC_FORMAT         0x30
#define SSPP_SRC_UNPACK_PATTERN 0x34

#define SCALE   2
#define MAX_FB  8

static const unsigned long sspp_off[] = {
    0x5000, 0x7000, 0x9000, 0xb000,         /* vig0-3 */
    0x25000, 0x27000, 0x29000, 0x2b000,     /* dma0-3 */
};

struct fb {
    uint8_t *mem;
    unsigned w, h, stride, bpp;
    int alpha_byte;     /* byte index of the alpha channel, or -1 */
};

static struct fb fbs[MAX_FB];
static int nfb = -1;    /* -1: not probed yet */

int screen_count(void)
{
    return nfb < 0 ? 0 : nfb;
}

static void probe(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *mdp;

    nfb = 0;
    if (fd < 0)
        return;
    mdp = mmap(NULL, 0x30000, PROT_READ, MAP_SHARED, fd, MDP_BASE);
    if (mdp == MAP_FAILED) {
        close(fd);
        return;
    }

    for (unsigned i = 0; i < sizeof(sspp_off) / sizeof(sspp_off[0]); i++) {
        volatile uint32_t *p = mdp + sspp_off[i] / 4;
        uint32_t size = p[SSPP_SRC_SIZE / 4];
        uint32_t addr = p[SSPP_SRC0_ADDR / 4];
        uint32_t stride = p[SSPP_SRC_YSTRIDE0 / 4] & 0xffff;
        uint32_t format = p[SSPP_SRC_FORMAT / 4];
        uint32_t unpack = p[SSPP_SRC_UNPACK_PATTERN / 4];
        struct fb *f = &fbs[nfb];
        void *m;

        if (addr < SPLASH_BASE || addr >= SPLASH_BASE + SPLASH_SIZE)
            continue;
        f->w = size & 0xffff;
        f->h = size >> 16;
        f->stride = stride;
        f->bpp = ((format >> 9) & 3) + 1;
        if (!f->w || !f->h || f->stride < f->w * f->bpp || f->bpp < 3)
            continue;
        /* Byte i holds component unpack[i]; component 3 is alpha. */
        f->alpha_byte = -1;
        if (f->bpp == 4)
            for (int b = 0; b < 4; b++)
                if (((unpack >> (8 * b)) & 0xff) == 3)
                    f->alpha_byte = b;
        m = mmap(NULL, (size_t)f->stride * f->h, PROT_READ | PROT_WRITE,
                 MAP_SHARED, fd, addr);
        if (m == MAP_FAILED)
            continue;
        f->mem = m;
        if (++nfb == MAX_FB)
            break;
    }
    munmap((void *)mdp, 0x30000);
    close(fd);
}

/* Fill one pixel of a scanline: white or black, so channel order does not
 * matter; the alpha byte, if any, is always opaque. */
static void pixel(const struct fb *f, uint8_t *px, int on)
{
    for (unsigned b = 0; b < f->bpp; b++)
        px[b] = ((int)b == f->alpha_byte || on) ? 0xff : 0x00;
}

/* Render each scanline of a text row once in local memory and copy it out
 * whole: the splash is mapped uncached, where per-pixel stores are slow. */
static void draw_line(struct fb *f, unsigned row, const char *s)
{
    static uint8_t scan[4 * 4096];
    unsigned cw = 8 * SCALE, ch = 16 * SCALE;
    unsigned cols = f->w / cw, y0 = row * ch;
    unsigned char text[512];

    if (y0 + ch > f->h || f->w * f->bpp > sizeof(scan))
        return;
    for (unsigned c = 0; c < cols && c < sizeof(text); c++)
        text[c] = (*s && *s != '\n') ? (unsigned char)*s++ : ' ';

    for (unsigned gy = 0; gy < 16; gy++) {
        for (unsigned x = 0; x < f->w; x++) {
            unsigned c = x / cw;
            int on = c < cols &&
                     (font8x16[16 * text[c] + gy] & (0x80 >> ((x % cw) / SCALE)));

            pixel(f, scan + x * f->bpp, on);
        }
        for (unsigned k = 0; k < SCALE; k++)
            memcpy(f->mem + (size_t)(y0 + gy * SCALE + k) * f->stride,
                   scan, (size_t)f->w * f->bpp);
    }
}

void screen_show(const char *const *lines, int n)
{
    if (nfb < 0)
        probe();
    for (int i = 0; i < nfb; i++) {
        unsigned rows = fbs[i].h / (16 * SCALE);

        for (unsigned r = 0; r < rows; r++)
            draw_line(&fbs[i], r, (int)r < n ? lines[r] : "");
    }
}
