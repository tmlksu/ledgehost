/* ledgehost-input — X11/XTest injection helper for ledgehostd
 * (Phase 1, decisions 8, 9, 10 of docs/phase-1-plan.md).
 *
 * stdin carries length-prefixed records only (a line protocol cannot
 * carry typed text):
 *   length (4, BE, <= 64 KiB) + body: op (1) + fields
 *   1 pointer  kind(1) 0=move 1=lDown 2=lUp 3=rDown 4=rUp, x(4) y(4)
 *              fractions of the frame x1e6, clamped to [0,1]
 *   2 scroll   dx(4) dy(4) fractions x1e6
 *   3 key      HID usage(2, BE), down(1)
 *   4 text     UTF-8 bytes (record length bounds it; <= 4096 chars)
 *   5 release-all  6 reset (drop all state)
 * stdout is never written; all logging is stderr. Exits on stdin EOF,
 * releasing held input and restoring the scratch keycode first.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/XKBlib.h>

/* The devprefix carries XTest.h but not its XInput.h prerequisite, and
 * no Xrandr.h at all: declare the small ABI surface we use (libXtst.so.6
 * is linked by soname) and take the source rectangle from the root
 * window — on this single-head target it is the primary CRTC's rect. */
extern int XTestQueryExtension(Display *, int *, int *, int *, int *);
extern int XTestFakeMotionEvent(Display *, int, int, int, unsigned long);
extern int XTestFakeKeyEvent(Display *, unsigned int, int, unsigned long);
extern int XTestFakeButtonEvent(Display *, unsigned int, int, unsigned long);
#define Button6 6
#define Button7 7

#include "generated/keymap.h"

static Display *dpy;
static int src_x, src_y, src_w, src_h;
static int min_kc, max_kc, scratch_kc;

/* held state: pressed X keycodes and mouse buttons */
static unsigned char held_kc[256];
static unsigned char held_btn[8];

/* scroll accumulators, in milli-fractions of the frame */
static long scroll_acc_x, scroll_acc_y;

/* token bucket: at most 240 input records per second */
static double bucket = 240;
static double bucket_last;

static void logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "input: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static double now_sec(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* MARK: source rectangle (primary RandR CRTC, else the root window) */

static void source_rect(void)
{
    Window root = DefaultRootWindow(dpy);
    src_x = src_y = 0;
    Window r;
    int x, y; unsigned w, h, bw, d;
    XGetGeometry(dpy, root, &r, &x, &y, &w, &h, &bw, &d);
    src_w = (int)w; src_h = (int)h;

    logf("source rect %dx%d+%d+%d (root window)", src_w, src_h, src_x, src_y);
}

/* MARK: held state */

static void hold_key(int kc, int down)
{
    if (kc >= min_kc && kc <= max_kc && kc < 256) {
        held_kc[kc] = down ? 1 : 0;
        XTestFakeKeyEvent(dpy, kc, down ? True : False, CurrentTime);
    }
}

static void hold_btn(int b, int down)
{
    held_btn[b & 7] = down ? 1 : 0;
    XTestFakeButtonEvent(dpy, b, down ? True : False, CurrentTime);
}

static void release_all(void)
{
    for (int kc = 0; kc < 256; kc++)
        if (held_kc[kc]) {
            held_kc[kc] = 0;
            XTestFakeKeyEvent(dpy, kc, False, CurrentTime);
        }
    for (int b = 1; b < 8; b++)
        if (held_btn[b]) {
            held_btn[b] = 0;
            XTestFakeButtonEvent(dpy, b, False, CurrentTime);
        }
    scroll_acc_x = scroll_acc_y = 0;
    XFlush(dpy);
}

/* MARK: scratch keycode (decision 8: reset at startup and exit) */

static void scratch_reset(void)
{
    if (scratch_kc) {
        KeySym none = NoSymbol;
        XChangeKeyboardMapping(dpy, scratch_kc, 1, &none, 1);
        XSync(dpy, False);
    }
}

static void scratch_set(KeySym sym)
{
    KeySym syms[1] = { sym };
    XChangeKeyboardMapping(dpy, scratch_kc, 1, syms, 1);
    XSync(dpy, False);      /* the keymap must be live before we press */
}

/* MARK: text typing
 * Fast path: find the keysym in the current keymap (with its shift
 * level) and press the matching key. Only characters absent from the
 * layout take the remap-a-scratch-keycode path. */

static KeySym char_keysym(unsigned int cp)
{
    if (cp >= 0x20 && cp <= 0x7e) return cp;              /* ASCII */
    if (cp >= 0xa0 && cp <= 0xff) return cp;              /* Latin-1 */
    if (cp > 0xff) return 0x01000000 | cp;                /* Unicode convention */
    return NoSymbol;
}

/* Decode one UTF-8 scalar; returns its length or 0 on bad input. */
static int utf8_at(const unsigned char *s, int n, unsigned int *cp)
{
    if (!n) return 0;
    if (s[0] < 0x80) { *cp = s[0]; return 1; }
    int len = s[0] < 0xe0 ? 2 : s[0] < 0xf0 ? 3 : 4;
    if (n < len) return 0;
    unsigned int v = s[0] & (0x7f >> len);
    for (int i = 1; i < len; i++) {
        if ((s[i] & 0xc0) != 0x80) return 0;
        v = (v << 6) | (s[i] & 0x3f);
    }
    *cp = v;
    return len;
}

static int shift_kc = -1;

static void type_char(unsigned int cp)
{
    KeySym sym = char_keysym(cp);
    if (!sym) return;

    /* search the keymap for the keysym and its level */
    int per = 0;
    KeySym *map = XGetKeyboardMapping(dpy, min_kc, max_kc - min_kc + 1, &per);
    int found_kc = 0, level = 0;
    if (map) {
        for (int kc = min_kc; kc <= max_kc && !found_kc; kc++)
            for (int l = 0; l < per && l < 4; l++)
                if (map[(kc - min_kc) * per + l] == sym) {
                    found_kc = kc; level = l; break;
                }
        XFree(map);
    }
    if (found_kc) {
        int need_shift = (level == 1);
        if (need_shift && shift_kc > 0)
            XTestFakeKeyEvent(dpy, shift_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, found_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, found_kc, False, CurrentTime);
        if (need_shift && shift_kc > 0)
            XTestFakeKeyEvent(dpy, shift_kc, False, CurrentTime);
    } else {
        /* absent from the layout: remap the scratch keycode briefly */
        scratch_set(sym);
        XTestFakeKeyEvent(dpy, scratch_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, scratch_kc, False, CurrentTime);
        scratch_reset();
    }
    XFlush(dpy);
}

/* MARK: ops */

static void op_pointer(const unsigned char *p, int n)
{
    if (n < 9) return;
    int kind = p[0];
    double x = (double)(int32_t)((p[1] << 24) | (p[2] << 16) | (p[3] << 8) | p[4]) / 1e6;
    double y = (double)(int32_t)((p[5] << 24) | (p[6] << 16) | (p[7] << 8) | p[8]) / 1e6;
    if (x < 0) x = 0;
    if (x > 1) x = 1;
    if (y < 0) y = 0;
    if (y > 1) y = 1;
    int px = src_x + (int)(x * (src_w - 1) + 0.5);
    int py = src_y + (int)(y * (src_h - 1) + 0.5);
    XTestFakeMotionEvent(dpy, -1, px, py, CurrentTime);
    switch (kind) {
    case 1: hold_btn(Button1, 1); break;
    case 2: hold_btn(Button1, 0); break;
    case 3: hold_btn(Button3, 1); break;
    case 4: hold_btn(Button3, 0); break;
    default: break;             /* 0 = move */
    }
    XFlush(dpy);
}

static void op_scroll(const unsigned char *p, int n)
{
    if (n < 8) return;
    scroll_acc_x += (int32_t)((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]);
    scroll_acc_y += (int32_t)((p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7]);
    /* one click per 1/24 of the frame height (~one wheel notch); the
     * leftover fraction is kept so sub-click deltas are not lost */
    long per = 1000000 / 24;
    while (scroll_acc_y >= per)  { hold_btn(Button4, 1); hold_btn(Button4, 0); scroll_acc_y -= per; }
    while (scroll_acc_y <= -per) { hold_btn(Button5, 1); hold_btn(Button5, 0); scroll_acc_y += per; }
    while (scroll_acc_x >= per)  { hold_btn(Button7, 1); hold_btn(Button7, 0); scroll_acc_x -= per; }
    while (scroll_acc_x <= -per) { hold_btn(Button6, 1); hold_btn(Button6, 0); scroll_acc_x += per; }
    XFlush(dpy);
}

static void op_key(const unsigned char *p, int n)
{
    if (n < 3) return;
    unsigned usage = (p[0] << 8) | p[1];
    int down = p[2] != 0;
    if (usage > KEYMAP_MAX_HID) { logf("drop: hid 0x%02x out of table", usage); return; }
    int xkc = keymap_hid_to_evdev[usage].xkc;
    if (!xkc) { logf("drop: hid 0x%02x unmapped", usage); return; }
    if (xkc < min_kc || xkc > max_kc) { logf("drop: xkc %d out of range", xkc); return; }
    hold_key(xkc, down);
    XFlush(dpy);
}

static void op_text(const unsigned char *p, int n)
{
    if (n > 4096 * 4) n = 4096 * 4;     /* the record length bounds it */
    int chars = 0;
    for (int i = 0; i < n && chars < 4096;) {
        unsigned int cp;
        int len = utf8_at(p + i, n - i, &cp);
        if (!len) { logf("drop: bad utf-8 at byte %d", i); return; }
        i += len; chars++;
        type_char(cp);
    }
}

/* MARK: input loop */

static int rate_ok(void)
{
    double now = now_sec();
    if (!bucket_last) bucket_last = now;
    bucket += (now - bucket_last) * 240;
    if (bucket > 240) bucket = 240;
    bucket_last = now;
    if (bucket < 1) return 0;
    bucket -= 1;
    return 1;
}

int main(void)
{
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    const char *disp = getenv("DISPLAY");
    dpy = XOpenDisplay(disp && *disp ? disp : ":0");
    if (!dpy) { logf("cannot open display"); return 2; }
    int ev, er, maj, min;
    if (!XTestQueryExtension(dpy, &ev, &er, &maj, &min)) {
        logf("no XTest extension"); return 2;
    }
    XDisplayKeycodes(dpy, &min_kc, &max_kc);
    scratch_kc = max_kc;                  /* last keycode, normally spare */
    shift_kc = XKeysymToKeycode(dpy, XStringToKeysym("Shift_L"));
    scratch_reset();                      /* never inherit a stale remap */
    source_rect();
    logf("up: keycodes %d..%d scratch %d shift %d", min_kc, max_kc, scratch_kc, shift_kc);

    unsigned char buf[64 * 1024];
    size_t have = 0;
    static unsigned char pending_move[9];
    static int pending_move_n = 0;
    for (;;) {
        ssize_t r = read(0, buf + have, sizeof buf - have);
        if (r == 0) break;                        /* stdin EOF */
        if (r < 0) { if (errno == EINTR) continue; break; }
        have += (size_t)r;
        size_t off = 0;
        while (have - off >= 5) {
            uint32_t len = (buf[off] << 24) | (buf[off+1] << 16) | (buf[off+2] << 8) | buf[off+3];
            if (len == 0 || len > sizeof buf - 4) { logf("bad record len %u", len); len = sizeof buf - 4; }
            if (have - off < 4 + len) break;
            const unsigned char *body = buf + off + 4;   /* len covers op + fields */
            int op = body[0];
            off += 4 + len;
            /* pointer moves coalesce: keep only the latest */
            if (op == 1 && body[1] == 0 && len - 1 == 9) {
                memcpy(pending_move, body + 1, 9);
                pending_move_n = 1;
                continue;
            }
            if (pending_move_n) { op_pointer(pending_move, 9); pending_move_n = 0; }
            if (!rate_ok()) continue;             /* over 240/s: drop */
            switch (op) {
            case 1: op_pointer(body + 1, len - 1); break;
            case 2: op_scroll(body + 1, len - 1); break;
            case 3: op_key(body + 1, len - 1); break;
            case 4: op_text(body + 1, len - 1); break;
            case 5: release_all(); break;
            case 6: release_all(); scroll_acc_x = scroll_acc_y = 0; break;
            default: logf("reject: unknown op %d", op); break;
            }
        }
        memmove(buf, buf + off, have - off);
        have -= off;
        if (have == sizeof buf) have = 0;         /* defensive */
    }
    if (pending_move_n) op_pointer(pending_move, 9);
    release_all();
    scratch_reset();
    logf("exit");
    return 0;
}
