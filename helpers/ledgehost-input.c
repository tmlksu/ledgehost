/* ledgehost-input — X11/XTest injection helper for ledgehostd
 * (Phase 1, decisions 8, 9, 10 of docs/phase-1-plan.md).
 *
 * stdin carries length-prefixed records only (a line protocol cannot
 * carry typed text):
 *   length (4, BE, <= REC_MAX below) + body: op (1) + fields
 *   1 pointer  kind(1) 0=move 1=lDown 2=lUp 3=rDown 4=rUp, x(4) y(4)
 *              fractions of the frame x1e6, clamped to [0,1]
 *   2 scroll   dx(4) dy(4) fractions x1e6; the wire event's x/y arrive
 *              as the preceding op-1 move (translator-side, audit S-E)
 *   3 key      HID usage(2, BE), down(1)
 *   4 text     UTF-8 bytes (record length bounds it; <= 4096 chars)
 *   5 release-all  6 reset (drop all state)
 *   7 set clipboard  UTF-8 text (<= 256 KiB); the helper takes the
 *              CLIPBOARD selection and serves it
 * stdout carries the same framing in the helper -> daemon direction:
 *   op 1 clipboard changed  UTF-8 text of a CLIPBOARD selection made
 *              by another X client (never what the helper itself set)
 * All logging is stderr; clipboard content is never logged. Exits on
 * stdin EOF, releasing held input and restoring the scratch keycode.
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
#include <X11/Xatom.h>
#include <sys/select.h>

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

/* XFixes 4.0 selection-owner-change notify, ABI declared directly
 * (libXfixes.so.3 is linked by soname; no header in the devprefix). */
extern int XFixesQueryExtension(Display *, int *, int *);
extern void XFixesSelectSelectionInput(Display *, Window, Atom, unsigned long);
#define XFixesSelectionNotify 0
#define XFixesSetSelectionOwnerNotifyMask (1L << 0)
#define XFixesSelectionWindowDestroyNotifyMask (1L << 1)
#define XFixesSelectionClientCloseNotifyMask (1L << 2)
typedef struct {
    int type;
    unsigned long serial;
    int send_event;
    Display *display;
    Window window;
    int subtype;
    Window owner;
    Atom selection;
    Time timestamp;
    Time selection_timestamp;
} XFixesSelectionNotifyEvent;

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

static void scratch_reset(void);  /* defined below */

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
    scratch_reset();
    scroll_acc_x = scroll_acc_y = 0;
    XFlush(dpy);
}

/* MARK: scratch keycode (decision 8: reset at startup and exit) */

static int scratch_live;                /* scratch_kc holds a keysym */

static void scratch_reset_force(int force)
{
    if (scratch_kc && (scratch_live || force)) {
        KeySym none = NoSymbol;
        XChangeKeyboardMapping(dpy, scratch_kc, 1, &none, 1);
        XSync(dpy, False);
        scratch_live = 0;
    }
}

static void scratch_reset(void) { scratch_reset_force(0); }

static void scratch_set(KeySym sym)
{
    KeySym syms[1] = { sym };
    XChangeKeyboardMapping(dpy, scratch_kc, 1, syms, 1);
    XSync(dpy, False);      /* the keymap must be live before we press */
    scratch_live = 1;
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
static double last_type_ms;             /* last char press of any kind */
static double last_scratch_ms;          /* pacing for scratch remaps */

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
    last_type_ms = now_sec();
    if (found_kc) {
        int need_shift = (level == 1);
        if (need_shift && shift_kc > 0)
            XTestFakeKeyEvent(dpy, shift_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, found_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, found_kc, False, CurrentTime);
        if (need_shift && shift_kc > 0)
            XTestFakeKeyEvent(dpy, shift_kc, False, CurrentTime);
    } else {
        /* absent from the layout: remap the scratch keycode and press.
         * The mapping STAYS until the next remap or reset: clients
         * translate keycode -> keysym with their own keymap cache,
         * which updates on the MappingNotify preceding this KeyPress.
         * Restoring immediately races that lookup and the press
         * resolves to NoSymbol (or the next char's keysym). */
        /* the consumer must absorb both the press before us and our
         * remap before it looks up this keycode */
        double t = now_sec();
        double since = last_scratch_ms > last_type_ms
                     ? t - last_scratch_ms : t - last_type_ms;
        double gap = since;
        if (gap < 0.030) {
            struct timespec ts;
            ts.tv_sec = 0; ts.tv_nsec = (long)((0.030 - gap) * 1e9);
            nanosleep(&ts, NULL);
        }
        scratch_set(sym);
        last_scratch_ms = last_type_ms = now_sec();
        XTestFakeKeyEvent(dpy, scratch_kc, True, CurrentTime);
        XTestFakeKeyEvent(dpy, scratch_kc, False, CurrentTime);
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
     * leftover fraction is kept so sub-click deltas are not lost. The
     * accumulators are bounded (audit S2/F6): one hostile record must
     * never enqueue tens of thousands of XTest events — the remainder is
     * carried, but only up to a few clicks per record. */
    long per = 1000000 / 24;
    long cap = 8 * per;             /* at most ~8 wheel clicks queued per axis */
    if (scroll_acc_x > cap)  scroll_acc_x = cap;
    if (scroll_acc_x < -cap) scroll_acc_x = -cap;
    if (scroll_acc_y > cap)  scroll_acc_y = cap;
    if (scroll_acc_y < -cap) scroll_acc_y = -cap;
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

/* MARK: clipboard (kind 32's X side)
 * The helper owns a hidden window to hold the CLIPBOARD selection for
 * device-supplied text, serves SelectionRequest out of it, and watches
 * other clients' copies via XFixes owner-change events (or a 0.5 s
 * owner+content poll when XFixes is absent). set_text tracks what the
 * helper itself placed: an owner move to our own window, or foreign
 * content identical to it, is never reported. */

static Atom a_clip, a_utf8, a_targets, a_text_utf8, a_text_plain,
    a_text, a_timestamp, a_prop;
static Window clip_win;
static unsigned char *set_text;         /* device text we own, or NULL */
static long set_len;
static Window clip_owner;               /* last seen CLIPBOARD owner */
static int xfixes_ev_base = -1;
static int conv_pending;                /* a conversion request is out */
static int conv_recheck;                /* owner moved while converting */
static double conv_deadline;            /* conv_pending expires at this time, or 0 */
static double conv_retry_at;            /* armed re-fetch timer, or 0 */
static int conv_retries;                /* retries spent on this owner */
static int clip_dbg = -1;               /* LH_CLIP_DEBUG: verbose decisions */

#define cdbg(...) do { if (clip_dbg) {         fprintf(stderr, "input: clipdbg: " __VA_ARGS__);         fputc('\n', stderr); } } while (0)

static const char *atom_name(Atom a)
{
    static char buf[64];
    if (!a) return "None";
    char *n = XGetAtomName(dpy, a);
    snprintf(buf, sizeof buf, "%s", n ? n : "?");
    if (n) XFree(n);
    return buf;
}

#define CLIP_MAX (256 * 1024)

/* Maximum valid stdin record: an op-7 (clipboard) record carries one op
 * byte + up to CLIP_MAX bytes of text. The daemon mirrors this bound as
 * InputRecord.maxRecordBytes in Sources/LedgehostCore/InputRecords.swift —
 * keep the two in sync. A record announcing len 0 or len > REC_MAX is
 * unrecoverable framing desync: the helper exits and the daemon restarts
 * it (clamping the announced length would reinterpret attacker-controlled
 * text bytes as further op records — audit F2/S16). */
#define REC_MAX (CLIP_MAX + 1)

static void write_all(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) { if (errno == EINTR) continue; return; }
        if (w == 0) return;
        p += w; n -= (size_t)w;
    }
}

static void emit_record(int op, const unsigned char *data, int n)
{
    /* helper -> daemon, same framing as stdin: len(4, BE) + op + fields */
    unsigned char hdr[5];
    uint32_t len = (uint32_t)n + 1;
    hdr[0] = len >> 24; hdr[1] = len >> 16; hdr[2] = len >> 8; hdr[3] = len;
    hdr[4] = (unsigned char)op;
    write_all(1, hdr, 5);
    if (n > 0) write_all(1, data, n);
}

static void serve_selection(XSelectionRequestEvent *req)
{
    cdbg("serve req: target=%s prop=%s set_len=%ld",
         atom_name(req->target), atom_name(req->property), set_len);
    XSelectionEvent ev = { 0 };
    ev.type = SelectionNotify;
    ev.display = req->display;
    ev.requestor = req->requestor;
    ev.selection = req->selection;
    ev.target = req->target;
    ev.time = req->time;
    ev.property = None;
    /* obsolete requestors pass property None: the target names it */
    Atom prop = req->property == None ? req->target : req->property;
    if (req->target == a_targets) {
        Atom list[7] = { a_targets, a_timestamp, a_utf8, a_text_utf8,
                         a_text_plain, a_text, XA_STRING };
        XChangeProperty(dpy, req->requestor, prop, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)list, 7);
        ev.property = prop;
    } else if (req->target == a_timestamp) {
        Time t = 0;
        XChangeProperty(dpy, req->requestor, prop, XA_INTEGER, 32,
                        PropModeReplace, (unsigned char *)&t, 1);
        ev.property = prop;
    } else if (set_text &&
               (req->target == a_utf8 || req->target == a_text_utf8 ||
                req->target == a_text_plain || req->target == a_text ||
                req->target == XA_STRING)) {
        XChangeProperty(dpy, req->requestor, prop, req->target, 8,
                        PropModeReplace, set_text, (int)set_len);
        ev.property = prop;
    }
    cdbg("serve resp: target=%s -> prop=%s",
         atom_name(req->target), atom_name(ev.property));
    XSendEvent(dpy, req->requestor, False, 0, (XEvent *)&ev);
}

static void fetch_clipboard_text(void)
{
    if (conv_pending) { conv_recheck = 1; return; }
    conv_pending = 1;
    /* conv_deadline bounds the wait for SelectionNotify (audit S3): an
     * owner that never answers would otherwise wedge all later host ->
     * device fetches until helper restart. */
    conv_deadline = now_sec() + 2.0;
    cdbg("fetch: asking owner %lu for %s", (unsigned long)clip_owner,
         atom_name(a_utf8));
    XConvertSelection(dpy, a_clip, a_utf8, a_prop, clip_win, CurrentTime);
    XFlush(dpy);
}

/* The CLIPBOARD selection's owner moved (event or poll): our own window
 * needs nothing done; another client is asked for its text. */
static void owner_moved(Window owner)
{
    clip_owner = owner;
    conv_retries = 0;
    conv_retry_at = 0;
    if (owner == clip_win || owner == None) return;
    fetch_clipboard_text();
}

static void got_selection_text(XSelectionEvent *sel)
{
    conv_pending = 0;
    conv_deadline = 0;
    if (sel->property == None || sel->target != a_utf8) {
        /* the owner refused this target or answered oddly — one
         * retry covers "owner mid-change" timing */
        if (conv_retries++ < 1) {
            conv_retry_at = now_sec() + 0.15;
            cdbg("fetch: refused/odd reply (prop=%s target=%s) — retry in 150ms",
                 atom_name(sel->property), atom_name(sel->target));
        } else
            cdbg("fetch: refused (prop=%s target=%s) — giving up",
                 atom_name(sel->property), atom_name(sel->target));
    }
    if (sel->property != None) {
        Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
        if (XGetWindowProperty(dpy, clip_win, sel->property, 0,
                               CLIP_MAX / 4 + 1, True, AnyPropertyType,
                               &type, &fmt, &n, &after, &data) == Success
            && data) {
            if (fmt != 8 || (after == 0 && n == 0)) {
                /* empty/odd reply — same retry as a refusal */
                if (conv_retries++ < 1) {
                    conv_retry_at = now_sec() + 0.15;
                    cdbg("fetch: empty/odd reply (fmt=%d n=%lu) — retry in 150ms",
                         fmt, n);
                } else
                    cdbg("fetch: empty/odd reply (fmt=%d n=%lu) — giving up", fmt, n);
            } else if (after == 0 && n > 0 && n <= CLIP_MAX) {
                if (!(set_text && n == (unsigned long)set_len &&
                      memcmp(data, set_text, n) == 0)) {
                    cdbg("fetch: got %lu byte(s) of %s — reporting", n,
                         atom_name(type));
                    emit_record(1, data, (int)n);
                } else
                    cdbg("fetch: %lu byte(s) match device text — suppressed", n);
            } else if (after > 0)
                logf("clipboard: dropped (over %d bytes)", CLIP_MAX);
            XFree(data);
        }
        XDeleteProperty(dpy, clip_win, sel->property);
    }
    if (conv_recheck) { conv_recheck = 0; owner_moved(XGetSelectionOwner(dpy, a_clip)); }
}

static void drain_x_events(void)
{
    while (XPending(dpy)) {
        XEvent ev;
        XNextEvent(dpy, &ev);
        if (xfixes_ev_base >= 0 && ev.type == xfixes_ev_base + XFixesSelectionNotify) {
            XFixesSelectionNotifyEvent *se = (XFixesSelectionNotifyEvent *)&ev;
            cdbg("xfixes event: owner=%lu subtype=%d",
                 (unsigned long)se->owner, se->subtype);
            /* subtype 0 (owner set) names the new owner; subtype 1
             * (owner's window destroyed) can hand ownership to a
             * clipboard manager — ask the server for the truth. */
            if (se->selection == a_clip && se->subtype == 0)
                owner_moved(se->owner);
            else if (se->selection == a_clip && se->subtype == 1)
                owner_moved(XGetSelectionOwner(dpy, a_clip));
        } else if (ev.type == SelectionRequest) {
            serve_selection(&ev.xselectionrequest);
        } else if (ev.type == SelectionNotify) {
            if (ev.xselection.selection == a_clip)
                got_selection_text(&ev.xselection);
        }
    }
    XFlush(dpy);
}

static void clipboard_init(void)
{
    a_clip = XInternAtom(dpy, "CLIPBOARD", False);
    a_utf8 = XInternAtom(dpy, "UTF8_STRING", False);
    a_targets = XInternAtom(dpy, "TARGETS", False);
    a_text_utf8 = XInternAtom(dpy, "text/plain;charset=utf-8", False);
    a_timestamp = XInternAtom(dpy, "TIMESTAMP", False);
    a_text_plain = XInternAtom(dpy, "text/plain", False);
    a_text = XInternAtom(dpy, "TEXT", False);
    a_prop = XInternAtom(dpy, "LEDGEHOST_CLIPBOARD", False);
    clip_win = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy), 0, 0, 1, 1,
                                 0, 0, 0);
    clip_dbg = getenv("LH_CLIP_DEBUG") != NULL;
    /* SelectionNotify/SelectionRequest need no mask on our own window;
     * mask SelectionClear so we notice losing ownership too. */
    XSelectInput(dpy, clip_win, PropertyChangeMask);
    clip_owner = XGetSelectionOwner(dpy, a_clip);
    int evb = 0, erb = 0;
    if (XFixesQueryExtension(dpy, &evb, &erb)) {
        xfixes_ev_base = evb;
        XFixesSelectSelectionInput(dpy, clip_win, a_clip,
                                   XFixesSetSelectionOwnerNotifyMask |
                                   XFixesSelectionWindowDestroyNotifyMask |
                                   XFixesSelectionClientCloseNotifyMask);
        logf("clipboard: watching CLIPBOARD via XFixes");
    } else {
        logf("clipboard: watching CLIPBOARD by 0.5 s poll (no XFixes)");
    }
}

static void clipboard_poll(void)
{
    Window owner = XGetSelectionOwner(dpy, a_clip);
    if (owner != clip_owner) owner_moved(owner);
}

/* op 7: a device's text becomes the host clipboard. */
static void op_clipboard(const unsigned char *p, int n)
{
    if (n < 1 || n > CLIP_MAX) { logf("drop: clipboard op bad len %d", n); return; }
    free(set_text);
    set_text = malloc(n);
    if (!set_text) return;
    memcpy(set_text, p, n); set_len = n;
    XSetSelectionOwner(dpy, a_clip, clip_win, CurrentTime);
    clip_owner = clip_win;
    XFlush(dpy);
    logf("clipboard: %d byte(s) owned from device", n);
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
    scratch_reset_force(1);               /* never inherit a stale remap */
    source_rect();
    clipboard_init();
    logf("up: keycodes %d..%d scratch %d shift %d", min_kc, max_kc, scratch_kc, shift_kc);

    /* Sized to hold a whole maximal record (4-byte header + REC_MAX) so a
     * legitimate device clipboard of CLIP_MAX bytes parses in one pass. */
    static unsigned char buf[4 + REC_MAX];
    size_t have = 0;
    static unsigned char pending_move[9];
    static int pending_move_n = 0;
    int xfd = ConnectionNumber(dpy);
    int quit = 0;
    double poll_next = now_sec() + 0.5;
    for (;;) {
        drain_x_events();
        if (xfixes_ev_base < 0) {
            double t = now_sec();
            if (t >= poll_next) { clipboard_poll(); poll_next = t + 0.5; }
        }
        if (conv_retry_at && now_sec() >= conv_retry_at) {
            conv_retry_at = 0;
            fetch_clipboard_text();
        }
        if (conv_pending && conv_deadline && now_sec() >= conv_deadline) {
            /* the owner never answered: stop waiting so later owner moves
             * are fetched instead of piling onto conv_recheck */
            conv_pending = 0;
            conv_deadline = 0;
            cdbg("fetch: no reply within deadline — rearming");
            if (conv_recheck) {
                conv_recheck = 0;
                owner_moved(XGetSelectionOwner(dpy, a_clip));
            }
        }
        fd_set rfds;
        FD_ZERO(&rfds); FD_SET(0, &rfds); FD_SET(xfd, &rfds);
        struct timeval tv = { 0,
            (conv_retry_at || conv_deadline) ? 100000 : 500000 };
        int s = select(xfd + 1, &rfds, NULL, NULL,
                       (xfixes_ev_base < 0 || conv_retry_at || conv_deadline)
                           ? &tv : NULL);
        if (s < 0) { if (errno == EINTR) continue; break; }
        if (s == 0 || !FD_ISSET(0, &rfds)) continue;
        ssize_t r = read(0, buf + have, sizeof buf - have);
        if (r == 0) break;                        /* stdin EOF */
        if (r < 0) { if (errno == EINTR) continue; break; }
        have += (size_t)r;
        size_t off = 0;
        int fatal = 0;
        while (have - off >= 5) {
            uint32_t len = (buf[off] << 24) | (buf[off+1] << 16) | (buf[off+2] << 8) | buf[off+3];
            if (len == 0 || len > REC_MAX) {
                /* unrecoverable desync — never clamp-and-parse
                 * (audit F2/S16); die so the daemon restarts us */
                logf("fatal: bad record len %u", len);
                fatal = 1;
                break;
            }
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
            case 7: op_clipboard(body + 1, len - 1); break;
            default: logf("reject: unknown op %d", op); break;
            }
        }
        if (fatal) break;
        memmove(buf, buf + off, have - off);
        have -= off;
        if (have == sizeof buf) have = 0;         /* defensive */
        if (quit) break;
    }
    if (pending_move_n) op_pointer(pending_move, 9);
    release_all();
    scratch_reset_force(1);
    logf("exit");
    return 0;
}
