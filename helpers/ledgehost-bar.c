/* ledgehost-bar — synthetic fast-moving progress bar for the
 * timestamp-jitter e2e test. An override-redirect window at a fixed
 * position (so the WM cannot hide, move, or stack it): a white
 * vertical bar sweeps right at 8 px per ~16.67 ms step and a 10-cell
 * binary strip encodes the step index mod 1024, so any decoded frame
 * yields both the bar position and the capture-order index.
 *
 *   ledgehost-bar [seconds]   (default 20)
 *   window: 1200x180 at screen (60,140), black background
 */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <X11/Xlib.h>

#define WIN_X 60
#define WIN_Y 140
#define WIN_W 1200
#define WIN_H 180
#define BAR_W 16
#define BAR_STEP 8
#define BAR_SLOTS 120             /* x = WIN_X + 20 + slot*8 */
#define NCELL 10
#define CELL_W 100                /* cells at WIN_X+50+i*100, y=+115 */

int main(int argc, char **argv)
{
    double secs = argc > 1 ? atof(argv[1]) : 20;
    Display *d = XOpenDisplay(NULL);
    if (!d) { fputs("bar: cannot open display\n", stderr); return 2; }
    XSetWindowAttributes at;
    at.override_redirect = True;
    at.background_pixel = BlackPixel(d, DefaultScreen(d));
    Window w = XCreateWindow(d, DefaultRootWindow(d), WIN_X, WIN_Y,
                             WIN_W, WIN_H, 0, CopyFromParent,
                             InputOutput, CopyFromParent,
                             CWOverrideRedirect | CWBackPixel, &at);
    XMapWindow(d, w);
    XFlush(d);
    GC white = XCreateGC(d, w, 0, NULL);
    XSetForeground(d, white, WhitePixel(d, DefaultScreen(d)));
    GC black = XCreateGC(d, w, 0, NULL);
    XSetForeground(d, black, BlackPixel(d, DefaultScreen(d)));

    struct timespec step = { 0, 16666667 };
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (long f = 0; ; f++) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double el = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        if (el > secs) break;
        int x = 20 + (int)(f % BAR_SLOTS) * BAR_STEP;
        XFillRectangle(d, w, black, 0, 0, WIN_W, 110);
        XFillRectangle(d, w, white, x, 10, BAR_W, 90);
        for (int i = 0; i < NCELL; i++)
            XFillRectangle(d, w, (f >> i) & 1 ? white : black,
                           50 + i * CELL_W, 115, CELL_W - 12, 50);
        XFlush(d);
        nanosleep(&step, NULL);
    }
    XCloseDisplay(d);
    return 0;
}
