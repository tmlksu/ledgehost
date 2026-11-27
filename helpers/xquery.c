/* xquery — tiny X state query/set tool for the input and clipboard
 * tests: prints the root pointer position and held keycodes/buttons,
 * and reads or writes the CLIPBOARD selection, so a scratch daemon's
 * effects can be verified without reading any window content.
 *
 *   xquery                   prints "ptr X Y buttons b1,b2 keys k1,k2"
 *   xquery clip get          prints "clip N byte(s): <text>" (or the
 *                            refusal/empty selection)
 *   xquery clip set TEXT [S] owns CLIPBOARD and serves TEXT to
 *                            requestors for S seconds (default 15)
 *   xquery activate NAME    raise + input-focus the first toplevel
 *                           whose WM_NAME contains NAME
 *   xquery focus            print the input-focus window's name
 *   xquery windows          one snapshot of listable windows:
 *                           "root <w> <h>", then "win <xid-hex> <x>
 *                           <y> <w> <h> <class> <title>" per
 *                           window (coordinates root-absolute, title
 *                           _NET_WM_NAME falling back to WM_NAME,
 *                           controls blanked), then "." — windows are
 *                           in _NET_CLIENT_LIST order. A window lists
 *                           only while it is viewable, non-empty and
 *                           not typed _NET_WM_WINDOW_TYPE_DESKTOP.
 *   xquery watch            snapshot, then a new snapshot ~100 ms after
 *                           each burst of client-list/configure/title
 *                           changes; exits when stdin closes (the
 *                           daemon holds it open).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
#include <unistd.h>
#include <sys/select.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

static Display *d;
static Atom a_clip, a_utf8, a_targets, a_text_utf8, a_prop;

static double now_sec(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void atoms(void)
{
    a_clip = XInternAtom(d, "CLIPBOARD", False);
    a_utf8 = XInternAtom(d, "UTF8_STRING", False);
    a_targets = XInternAtom(d, "TARGETS", False);
    a_text_utf8 = XInternAtom(d, "text/plain;charset=utf-8", False);
    a_prop = XInternAtom(d, "XQUERY_CLIP", False);
}

static void serve(XSelectionRequestEvent *req, const char *text, long n)
{
    XSelectionEvent ev = { 0 };
    ev.type = SelectionNotify;
    ev.display = req->display;
    ev.requestor = req->requestor;
    ev.selection = req->selection;
    ev.target = req->target;
    ev.time = req->time;
    ev.property = None;
    if (req->target == a_targets) {
        Atom list[4] = { a_targets, a_utf8, a_text_utf8, XA_STRING };
        XChangeProperty(d, req->requestor, req->property, XA_ATOM, 32,
                        PropModeReplace, (unsigned char *)list, 4);
        ev.property = req->property;
    } else if (req->target == a_utf8 || req->target == a_text_utf8 ||
               req->target == XA_STRING) {
        XChangeProperty(d, req->requestor, req->property, req->target, 8,
                        PropModeReplace, (unsigned char *)text, (int)n);
        ev.property = req->property;
    }
    XSendEvent(d, req->requestor, False, 0, (XEvent *)&ev);
    XFlush(d);
}

static int clip_get2(Window win, Atom prop)
{
    if (XGetSelectionOwner(d, a_clip) == None) {
        puts("clip: no owner"); return 1;
    }
    XConvertSelection(d, a_clip, a_utf8, prop, win, CurrentTime);
    XFlush(d);
    double deadline = now_sec() + 5;
    while (now_sec() < deadline) {
        while (XPending(d)) {
            XEvent ev; XNextEvent(d, &ev);
            if (ev.type != SelectionNotify) continue;
            if (ev.xselection.property == None) {
                puts("clip: conversion refused"); return 1;
            }
            Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
            if (XGetWindowProperty(d, win, ev.xselection.property, 0, 1 << 20, True,
                                   AnyPropertyType, &type, &fmt, &n,
                                   &after, &data) != Success || !data) {
                puts("clip: property read failed"); return 1;
            }
            printf("clip %lu byte(s): %.*s\n", n, (int)n, data);
            XFree(data);
            return 0;
        }
        struct timespec ts = { 0, 20 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    puts("clip: timed out"); return 1;
}

static char *win_name(Window w)
{
    static char buf[256];
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    Atom wmn = XInternAtom(d, "WM_NAME", False);
    buf[0] = 0;
    if (XGetWindowProperty(d, w, wmn, 0, 255, False, AnyPropertyType,
                           &type, &fmt, &n, &after, &data) == Success && data) {
        snprintf(buf, sizeof buf, "%.*s", (int)(n < 255 ? n : 255), data);
        XFree(data);
    }
    return buf;
}

static int activate(Window root, const char *name)
{
    Atom cl = XInternAtom(d, "_NET_CLIENT_LIST", False);
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(d, root, cl, 0, 1024, False, XA_WINDOW,
                           &type, &fmt, &n, &after, &data) != Success || !data)
        { fputs("xquery: no _NET_CLIENT_LIST\n", stderr); return 1; }
    Window *list = (Window *)data;
    Window found = None;
    for (unsigned long i = 0; i < n; i++) {
        char lowname[256], lowneedle[256];
        snprintf(lowname, sizeof lowname, "%s", win_name(list[i]));
        snprintf(lowneedle, sizeof lowneedle, "%s", name);
        for (char *c = lowname; *c; c++) *c = tolower((unsigned char)*c);
        for (char *c = lowneedle; *c; c++) *c = tolower((unsigned char)*c);
        if (strstr(lowname, lowneedle)) { found = list[i]; break; }
    }
    XFree(data);
    if (!found) { fprintf(stderr, "xquery: no window matching %s\n", name); return 1; }
    XRaiseWindow(d, found);
    XSetInputFocus(d, found, RevertToParent, CurrentTime);
    XFlush(d);
    printf("activated 0x%lx %s\n", (unsigned long)found, win_name(found));
    return 0;
}

static int focus_name(Window root)
{
    Window f = None; int rev = 0;
    XGetInputFocus(d, &f, &rev);
    if (f == None || f == PointerRoot) { puts("focus: none"); return 1; }
    printf("focus 0x%lx %s\n", (unsigned long)f, win_name(f));
    return 0;
}

static int clip_get(Window win) { return clip_get2(win, a_prop); }

/* MARK: window enumeration (phase 2 — per-window sources)
 * _NET_CLIENT_LIST is the set of managed clients, in mapping order.
 * A window lists while it is viewable, non-empty and not the desktop
 * window itself; docks/panels are real content and stay listed. */

static Atom a_client_list, a_net_name, a_wm_name, a_wtype, a_wtype_desktop;

static void win_atoms(void)
{
    a_client_list = XInternAtom(d, "_NET_CLIENT_LIST", False);
    a_net_name    = XInternAtom(d, "_NET_WM_NAME", False);
    a_wm_name     = XInternAtom(d, "WM_NAME", False);
    a_wtype       = XInternAtom(d, "_NET_WM_WINDOW_TYPE", False);
    a_wtype_desktop = XInternAtom(d, "_NET_WM_WINDOW_TYPE_DESKTOP", False);
}

static unsigned char *prop(Window w, Atom a, Atom want, unsigned long *n)
{
    Atom type; int fmt; unsigned long after; unsigned char *data = NULL;
    if (XGetWindowProperty(d, w, a, 0, ~0L, False, want,
                           &type, &fmt, n, &after, &data) != Success || !data)
        return NULL;
    return data;
}

/* The display title: _NET_WM_NAME, else WM_NAME, one line, controls
 * blanked so a hostile title cannot forge snapshot lines. */
static void win_title(Window w, char *buf, int n)
{
    unsigned long len = 0;
    unsigned char *p = prop(w, a_net_name, a_utf8, &len);
    if (p && !len) { XFree(p); p = NULL; }   /* _NET_WM_NAME set, wrong type */
    if (!p) p = prop(w, a_net_name, AnyPropertyType, &len);
    if (!p) p = prop(w, a_wm_name, AnyPropertyType, &len);
    buf[0] = 0;
    if (p) {
        int m = (int)(len < (unsigned long)(n - 1) ? len : (unsigned long)(n - 1));
        memcpy(buf, p, m); buf[m] = 0;
        XFree(p);
    }
    for (int i = 0; buf[i]; i++)
        if ((unsigned char)buf[i] < 0x20 || buf[i] == 0x7f) buf[i] = ' ';
}

/* WM_CLASS is "instance\0class\0"; the class part names the app.
 * Whitespace and controls fold to "_" so the column never splits. */
static void win_class(Window w, char *buf, int n)
{
    unsigned long len = 0;
    unsigned char *p = prop(w, XInternAtom(d, "WM_CLASS", False), XA_STRING, &len);
    buf[0] = 0;
    if (p) {
        size_t first = strnlen((char *)p, len);
        const char *cls = first + 1 < len ? (char *)p + first + 1 : (char *)p;
        snprintf(buf, n, "%s", cls);
        XFree(p);
    }
    for (int i = 0; buf[i]; i++)
        if ((unsigned char)buf[i] <= 0x20 || buf[i] == 0x7f) buf[i] = '_';
    if (!buf[0]) snprintf(buf, n, "-");
}

static int win_is_desktop(Window w)
{
    unsigned long n = 0;
    unsigned char *p = prop(w, a_wtype, XA_ATOM, &n);
    int desk = 0;
    if (p) {
        Atom *t = (Atom *)p;
        for (unsigned long i = 0; i < n; i++)
            if (t[i] == a_wtype_desktop) desk = 1;
        XFree(p);
    }
    return desk;
}

/* Snapshot the listable windows: a "root" line (the desktop rect the
 * desktop source captures and input defaults to), one "win" line per
 * window, "." terminator. */
static void win_snapshot(Window root)
{
    XWindowAttributes ra;
    if (XGetWindowAttributes(d, root, &ra))
        printf("root %d %d\n", (int)ra.width, (int)ra.height);
    unsigned long n = 0;
    unsigned char *p = prop(root, a_client_list, XA_WINDOW, &n);
    if (!p) { puts("."); fflush(stdout); return; }
    Window *list = (Window *)p;
    for (unsigned long i = 0; i < n; i++) {
        Window w = list[i];
        XWindowAttributes wa;
        if (!XGetWindowAttributes(d, w, &wa)) continue;
        if (wa.map_state != IsViewable || wa.width <= 0 || wa.height <= 0)
            continue;
        if (wa.override_redirect) continue;
        if (win_is_desktop(w)) continue;
        int rx = 0, ry = 0; Window child;
        if (!XTranslateCoordinates(d, w, root, 0, 0, &rx, &ry, &child))
            { rx = wa.x; ry = wa.y; }
        char title[256], cls[128];
        win_title(w, title, sizeof title);
        win_class(w, cls, sizeof cls);
        printf("win %lx %d %d %d %d %s %s\n", (unsigned long)w,
               rx, ry, (int)wa.width, (int)wa.height, cls, title);
    }
    XFree(p);
    puts(".");
    fflush(stdout);
}

/* StructureNotify+PropertyChange on every client so title, geometry,
 * map and stack changes wake the watch; refreshed after each snapshot
 * because the set itself may have moved. */
static void select_clients(Window root)
{
    unsigned long n = 0;
    unsigned char *p = prop(root, a_client_list, XA_WINDOW, &n);
    if (!p) return;
    Window *list = (Window *)p;
    for (unsigned long i = 0; i < n; i++)
        XSelectInput(d, list[i], PropertyChangeMask | StructureNotifyMask);
    XFree(p);
}

/* Watch the listed windows' state; re-snapshot ~100 ms after each
 * burst of change (create/destroy/map/configure/title). stdin EOF
 * exits — the daemon holds the pipe open. */
static int watch_windows(Window root)
{
    win_atoms();
    XSelectInput(d, root, PropertyChangeMask | SubstructureNotifyMask);
    select_clients(root);
    win_snapshot(root);
    int xfd = ConnectionNumber(d);
    int dirty = 0;
    double last_ev = 0;
    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds); FD_SET(xfd, &rfds); FD_SET(0, &rfds);
        struct timeval tv = { 0, dirty ? 100 * 1000 : 500 * 1000 };
        int r = select(xfd + 1, &rfds, NULL, NULL, &tv);
        if (r > 0 && FD_ISSET(0, &rfds)) {
            char b[64];
            if (read(0, b, sizeof b) <= 0) return 0;   /* daemon gone */
        }
        while (XPending(d)) {
            XEvent ev;
            XNextEvent(d, &ev);
            switch (ev.type) {
            case CreateNotify: case DestroyNotify: case MapNotify:
            case UnmapNotify: case ConfigureNotify: case ReparentNotify:
            case CirculateNotify:
                dirty = 1; last_ev = now_sec(); break;
            case PropertyNotify:
                if (ev.xproperty.atom == a_client_list ||
                    ev.xproperty.atom == a_net_name ||
                    ev.xproperty.atom == a_wm_name)
                    { dirty = 1; last_ev = now_sec(); }
                break;
            default: break;
            }
        }
        if (dirty && now_sec() - last_ev >= 0.1) {
            select_clients(root);
            win_snapshot(root);
            dirty = 0;
        }
    }
}

static int clip_wait(Window win, double secs)
{
    /* poll until CLIPBOARD has an owner, then fetch like clip get */
    double until = now_sec() + secs;
    while (now_sec() < until) {
        if (XGetSelectionOwner(d, a_clip) != None)
            return clip_get(win);
        struct timespec ts = { 0, 100 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    puts("clip: no owner before timeout"); return 1;
}

static int clip_set(Window win, const char *text, double secs)
{
    long n = (long)strlen(text);
    XSetSelectionOwner(d, a_clip, win, CurrentTime);
    XFlush(d);
    if (XGetSelectionOwner(d, a_clip) != win) {
        fputs("clip: failed to own selection\n", stderr); return 1;
    }
    double until = now_sec() + secs;
    while (now_sec() < until) {
        while (XPending(d)) {
            XEvent ev; XNextEvent(d, &ev);
            if (ev.type == SelectionRequest)
                serve(&ev.xselectionrequest, text, n);
        }
        struct timespec ts = { 0, 20 * 1000 * 1000 };
        nanosleep(&ts, NULL);
    }
    return 0;
}

int main(int argc, char **argv)
{
    d = XOpenDisplay(NULL);
    if (!d) { fputs("xquery: cannot open display\n", stderr); return 2; }
    Window root = DefaultRootWindow(d);
    atoms();
    Window win = XCreateSimpleWindow(d, root, 0, 0, 1, 1, 0, 0, 0);

    if (argc >= 3 && !strcmp(argv[1], "clip-legacy")) {
        /* obsolete convention: SelectionRequest with property None;
         * we must pass the TARGET as the property ourselves */
        int rc;
        if (!strcmp(argv[2], "get"))
            rc = clip_get2(win, None);
        else { fputs("usage: xquery clip-legacy get\n", stderr); return 64; }
        XDestroyWindow(d, win);
        XCloseDisplay(d);
        return rc;
    }
    if (argc >= 3 && !strcmp(argv[1], "activate"))
        { int rc = activate(root, argv[2]); XCloseDisplay(d); return rc; }
    if (argc >= 2 && !strcmp(argv[1], "focus"))
        { int rc = focus_name(root); XCloseDisplay(d); return rc; }
    if (argc >= 2 && !strcmp(argv[1], "windows"))
        { win_atoms(); win_snapshot(root); XCloseDisplay(d); return 0; }
    if (argc >= 2 && !strcmp(argv[1], "watch"))
        { int rc = watch_windows(root); XCloseDisplay(d); return rc; }
    if (argc >= 3 && !strcmp(argv[1], "clip")) {
        int rc;
        if (!strcmp(argv[2], "get"))
            rc = clip_get(win);
        else if (!strcmp(argv[2], "wait"))
            rc = clip_wait(win, argc >= 4 ? atof(argv[3]) : 15);
        else if (!strcmp(argv[2], "set") && argc >= 4)
            rc = clip_set(win, argv[3], argc >= 5 ? atof(argv[4]) : 15);
        else {
            fputs("usage: xquery clip get | clip set TEXT [seconds]\n", stderr);
            return 64;
        }
        XDestroyWindow(d, win);
        XCloseDisplay(d);
        return rc;
    }

    int rx, ry, wx, wy; unsigned mask; Window rr, cw;
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
    XDestroyWindow(d, win);
    XCloseDisplay(d);
    return 0;
}
