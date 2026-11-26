/* xquery — tiny X state query used by the input-path tests: prints the
 * root pointer position and the currently-held keycodes/buttons, so a
 * scratch daemon's injected input can be verified without reading any
 * window content.
 *
 *   xquery            prints "ptr X Y buttons b1,b2 keys k1,k2"
 */
#include <stdio.h>
#include <string.h>
#include <X11/Xlib.h>

int main(void)
{
    Display *d = XOpenDisplay(NULL);
    if (!d) { fputs("xquery: cannot open display\n", stderr); return 2; }
    Window root = DefaultRootWindow(d), rr, cw;
    int rx, ry, wx, wy; unsigned mask;
    if (!XQueryPointer(d, root, &rr, &cw, &rx, &ry, &wx, &wy, &mask))
        { fputs("xquery: pointer off screen\n", stderr); return 2; }
    printf("ptr %d %d buttons", rx, ry);
    for (int b = 1; b <= 7; b++)
        if (mask & (1 << (b + 7))) printf(" %d", b);
    char keys[32];
    XQueryKeymap(d, keys);
    printf(" keys");
    for (int kc = 0; kc < 256; kc++)
        if (keys[kc / 8] & (1 << (kc % 8))) printf(" %d", kc);
    printf("\n");
    XCloseDisplay(d);
    return 0;
}
