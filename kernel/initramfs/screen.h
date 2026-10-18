#ifndef DUO2_SCREEN_H
#define DUO2_SCREEN_H

/* Draw lines of text over the splash on every screen found; extra rows are
 * cleared. Probes the display controller on first use. */
void screen_show(const char *const *lines, int n);

/* Number of splash buffers found (0 if none, or not probed yet). */
int screen_count(void);

#endif
