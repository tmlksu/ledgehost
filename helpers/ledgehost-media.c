/* ledgehost-media — capture + HEVC encode helper for ledgehostd
 * (Phase 1, decisions 1, 7 and 11 of docs/phase-1-plan.md).
 *
 * stdout carries nothing but framed records:
 *   magic "LHM1" (4), version (1) = 1, tag (1): 1 = access unit,
 *   2 = parameter sets; flags (1): bit 0 = keyframe; reserved (1);
 *   capture timestamp (8, BE Double bit-pattern, wall-clock seconds);
 *   payload length (4, BE) <= 32 MiB.
 * A sets record's payload is the VPS/SPS/PPS as Annex B, concatenated;
 * it is emitted whenever the sets bytes change, before the AU that
 * carries them. An AU record's payload is one Annex B access unit,
 * parameter sets included if the encoder emitted them.
 *
 * stdin takes line commands: "KEYFRAME", "SET_BITRATE <bps>", "STOP".
 * All logging is stderr only. The helper exits on stdin EOF, stdout
 * EPIPE, or the parent's death (PR_SET_PDEATHSIG).
 *
 * Usage:
 *   ledgehost-media --source x11|test [--x N --y N --width N --height N]
 *                   [--fps N] [--bitrate BPS] [--convert cpu|gpu]
 *                   [--pattern N] [--frames N]
 * --convert cpu is the measured primary path (P1-M0); gpu is the
 * measured fallback. --frames exits after N AUs (fixture capture).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

#include <glib-unix.h>
#include <gst/gst.h>
#include <gst/app/app.h>
#include <gst/video/video.h>

#define TAG_AU   1
#define TAG_SETS 2
#define MAX_PAYLOAD (32u << 20)

static GMainLoop *loop;
static GstElement *encoder;
static int write_failed;

/* Capture timestamps: buffer PTS is pipeline-clock based, so the
 * wall-clock of a frame is rt0 + (pts - pts0). rt0 is re-anchored
 * periodically so clock slew cannot accumulate. */
static double rt0;
static gint64 pts0 = -1;
static double last_latency_ms;
static guint n_records;
static guint frames_this_second;
static GstClock *pipe_clock;

static double now_realtime(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int write_all(const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(STDOUT_FILENO, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int write_record(int tag, int keyframe, double ts,
                        const guint8 *payload, guint32 len)
{
    if (len > MAX_PAYLOAD || write_failed)
        return -1;
    guint8 h[20];
    memcpy(h, "LHM1", 4);
    h[4] = 1;                                   /* version */
    h[5] = (guint8)tag;
    h[6] = keyframe ? 1 : 0;
    h[7] = 0;
    guint64 tbits;
    memcpy(&tbits, &ts, 8);
    for (int i = 0; i < 8; i++)
        h[8 + i] = (guint8)(tbits >> (56 - 8 * i));
    h[16] = (guint8)(len >> 24);
    h[17] = (guint8)(len >> 16);
    h[18] = (guint8)(len >> 8);
    h[19] = (guint8)len;
    if (write_all(h, sizeof h) < 0 || write_all(payload, len) < 0) {
        write_failed = 1;
        g_main_loop_quit(loop);
        return -1;
    }
    return 0;
}

/* Annex B scan: collect the VPS/SPS/PPS NALs (types 32/33/34) of an
 * access-unit buffer, each re-prefixed with a 4-byte start code.
 * A NAL runs from after a 00 00 01 code to the next code; any extra
 * zero before a code stays on the tail of the NAL before it — the
 * daemon's converter uses the same convention, so bytes are stable. */
static void scan_sets(const guint8 *d, gsize n, GByteArray *out)
{
    gsize i = 0;
    while (i + 3 <= n) {
        if (d[i] || d[i + 1] || d[i + 2] != 1) { i++; continue; }
        gsize nal = i + 3;
        if (nal >= n) break;
        int type = (d[nal] >> 1) & 0x3f;
        gsize j = nal;
        while (j + 3 <= n) {
            if (!d[j] && !d[j + 1] && d[j + 2] == 1) break;
            j++;
        }
        if (type == 32 || type == 33 || type == 34) {
            static const guint8 sc[4] = {0, 0, 0, 1};
            g_byte_array_append(out, sc, 4);
            g_byte_array_append(out, d + nal, j - nal);
        }
        i = j;
    }
}

static GByteArray *last_sets;
static long long want_frames;
static guint au_records;

static GstFlowReturn on_sample(GstAppSink *sink, gpointer data)
{
    (void)data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample)
        return GST_FLOW_EOS;
    GstBuffer *buf = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (!buf || !gst_buffer_map(buf, &map, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_ERROR;
    }

    gint64 pts = GST_BUFFER_PTS(buf);
    if (pts0 < 0) {
        pts0 = pts;
        rt0 = now_realtime();
    }
    /* re-anchor about every 5 s of stream so slew cannot drift */
    if (n_records && n_records % 300 == 0)
        rt0 += now_realtime() - (rt0 + (double)(pts - pts0) / 1e9);
    double ts = rt0 + (double)(pts - pts0) / 1e9;
    last_latency_ms = (now_realtime() - ts) * 1000.0;
    n_records++;
    frames_this_second++;

    /* parameter sets first, when they change */
    GByteArray *sets = g_byte_array_new();
    scan_sets(map.data, map.size, sets);
    if (sets->len && (!last_sets || last_sets->len != sets->len ||
                      memcmp(last_sets->data, sets->data, sets->len))) {
        if (last_sets)
            g_byte_array_unref(last_sets);
        last_sets = g_byte_array_new();
        g_byte_array_append(last_sets, sets->data, sets->len);
        if (write_record(TAG_SETS, 0, ts, sets->data, sets->len) < 0)
            goto out;
    }
    g_byte_array_unref(sets);

    int keyframe = !GST_BUFFER_FLAG_IS_SET(buf, GST_BUFFER_FLAG_DELTA_UNIT);
    if (write_record(TAG_AU, keyframe, ts, map.data, (guint32)map.size) < 0)
        goto out;
    if (want_frames > 0 && ++au_records >= (guint)want_frames)
        g_main_loop_quit(loop);
out:
    gst_buffer_unmap(buf, &map);
    gst_sample_unref(sample);
    return write_failed ? GST_FLOW_ERROR : GST_FLOW_OK;
}

static gboolean on_stdin(gint fd, GIOCondition cond, gpointer data)
{
    (void)data;
    if (cond & (G_IO_HUP | G_IO_ERR)) {
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }
    char buf[256];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    if (n <= 0) {
        g_main_loop_quit(loop);         /* stdin EOF */
        return G_SOURCE_REMOVE;
    }
    buf[n] = 0;
    /* commands are whole lines; the daemon only ever sends them one
     * per write, but accept several per read and take the first field */
    for (char *p = buf; *p; ) {
        char *e = p;
        while (*e && *e != '\n') e++;
        if (!*e) break;                 /* unterminated tail: ignore */
        *e++ = 0;
        unsigned long long v = 0;
        if (!strcmp(p, "KEYFRAME")) {
            gst_element_send_event(encoder,
                gst_video_event_new_upstream_force_key_unit(
                    GST_CLOCK_TIME_NONE, TRUE, 0));
        } else if (!strcmp(p, "STOP")) {
            g_main_loop_quit(loop);
            return G_SOURCE_REMOVE;
        } else if (sscanf(p, "SET_BITRATE %llu", &v) == 1) {
            guint now = 0;
            g_object_set(encoder, "bitrate", (guint)(v / 1000), NULL);
            g_object_get(encoder, "bitrate", &now, NULL);
            fprintf(stderr, "media: bitrate now %u kbps\n", now);
        } else if (*p) {
            fprintf(stderr, "media: unknown command '%s'\n", p);
        }
        p = e;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean on_bus(GstBus *bus, GstMessage *msg, gpointer data)
{
    (void)bus; (void)data;
    switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
        GError *e = NULL;
        gchar *dbg = NULL;
        gst_message_parse_error(msg, &e, &dbg);
        fprintf(stderr, "media: pipeline error: %s (%s)\n",
                e ? e->message : "?", dbg ? dbg : "-");
        g_clear_error(&e);
        g_free(dbg);
        g_main_loop_quit(loop);
        break;
    }
    case GST_MESSAGE_EOS:
        g_main_loop_quit(loop);
        break;
    default:
        break;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean stats_tick(gpointer data)
{
    (void)data;
    if (frames_this_second)
        fprintf(stderr, "media: %u au/s, capture->au-out %.1f ms\n",
                frames_this_second, last_latency_ms);
    frames_this_second = 0;
    return G_SOURCE_CONTINUE;
}

static void usage(void)
{
    fputs("usage: ledgehost-media --source x11|test [options]\n"
          "  --x --y --width --height  capture rect (x11) or size (test)\n"
          "  --fps N        default 60\n"
          "  --bitrate BPS  bits per second, default 15000000\n"
          "  --convert cpu|gpu  cpu = videoconvert (primary), gpu = vapostproc\n"
          "  --pattern N    videotestsrc pattern (test source)\n"
          "  --frames N     exit after N access units (fixture capture)\n",
          stderr);
    exit(64);
}

int main(int argc, char **argv)
{
    const char *source = NULL, *convert = "cpu";
    int x = -1, y = -1, w = 0, h = 0, fps = 60, pattern = 18;
    long long bitrate = 15000000;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        #define ARG(v) (i + 1 < argc ? argv[++i] : (usage(), (char*)0))
        if (!strcmp(a, "--source")) source = ARG();
        else if (!strcmp(a, "--x")) x = atoi(ARG());
        else if (!strcmp(a, "--y")) y = atoi(ARG());
        else if (!strcmp(a, "--width")) w = atoi(ARG());
        else if (!strcmp(a, "--height")) h = atoi(ARG());
        else if (!strcmp(a, "--fps")) fps = atoi(ARG());
        else if (!strcmp(a, "--bitrate")) bitrate = atoll(ARG());
        else if (!strcmp(a, "--convert")) convert = ARG();
        else if (!strcmp(a, "--pattern")) pattern = atoi(ARG());
        else if (!strcmp(a, "--frames")) want_frames = atoll(ARG());
        else usage();
        #undef ARG
    }
    if (!source || (strcmp(source, "x11") && strcmp(source, "test")))
        usage();
    if (fps < 1 || fps > 240 || bitrate <= 0 || w < 0 || h < 0)
        usage();

    /* A dead parent must never leave a capturing pipeline behind. */
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    signal(SIGPIPE, SIG_IGN);
    /* An IDR is not dozens of read wakeups on the daemon's side. */
    fcntl(STDOUT_FILENO, F_SETPIPE_SZ, 1 << 20);

    gst_init(NULL, NULL);

    /* encoder: msdkh265enc. vah265lpenc (the planned element) cannot
     * insert a mid-stream IDR on this iGPU — its force-key-unit path
     * "promotes P to I" (gstvah265enc.c), producing a non-IDR I-slice a
     * joining decoder cannot start from. msdkh265enc answers the same
     * request with a real IDR (NAL 19 + in-band sets), verified P1-M1.
     * gop-size=300 is the same 5 s safety net; msdk's VBV knob is
     * max-vbv-bitrate (a rate, not a size) and is left at auto.
     * b-frames=0: with B-frames the wire order is DECODE order, so
     * presentation timestamps jitter ±a few frames and the client
     * shows backward steps on fast motion (measured: ~50% of AU
     * deltas non-monotonic, ±17-83 ms). Without B-frames, decode
     * order IS presentation order — monotonic by construction, and
     * one reorder-depth of encode latency disappears too. */
    guint kbps = (guint)(bitrate / 1000);
    char pipe_str[2048];
    if (!strcmp(source, "x11")) {
        char rect[128] = "";
        if (x >= 0 && y >= 0 && w > 0 && h > 0)
            snprintf(rect, sizeof rect, " startx=%d starty=%d endx=%d endy=%d",
                     x, y, x + w - 1, y + h - 1);
        const char *conv = !strcmp(convert, "gpu")
            ? "vapostproc ! video/x-raw(memory:VAMemory),format=NV12"
            : "videoconvert ! video/x-raw,format=NV12";
        snprintf(pipe_str, sizeof pipe_str,
            "ximagesrc name=src use-damage=false show-pointer=false%s "
            "! video/x-raw,framerate=%d/1 ! %s "
            "! queue leaky=downstream max-size-buffers=1 "
            "! msdkh265enc name=enc rate-control=cbr bitrate=%u gop-size=300 "
            "b-frames=0 b-pyramid=false b-adapt=off "
            "! h265parse ! video/x-h265,stream-format=byte-stream,alignment=au "
            "! appsink name=sink emit-signals=true max-buffers=8 sync=false",
            rect, fps, conv, kbps);
    } else {
        if (w <= 0) w = 640;
        if (h <= 0) h = 480;
        snprintf(pipe_str, sizeof pipe_str,
            "videotestsrc name=src is-live=true pattern=%d "
            "! video/x-raw,framerate=%d/1,width=%d,height=%d "
            "! videoconvert ! video/x-raw,format=NV12 "
            "! queue leaky=downstream max-size-buffers=1 "
            "! msdkh265enc name=enc rate-control=cbr bitrate=%u gop-size=300 "
            "b-frames=0 b-pyramid=false b-adapt=off "
            "! h265parse ! video/x-h265,stream-format=byte-stream,alignment=au "
            "! appsink name=sink emit-signals=true max-buffers=8 sync=false",
            pattern, fps, w, h, kbps);
    }

    GError *err = NULL;
    GstElement *pipe = gst_parse_launch(pipe_str, &err);
    if (!pipe) {
        fprintf(stderr, "media: cannot parse pipeline: %s\n",
                err ? err->message : "?");
        return 2;
    }
    encoder = gst_bin_get_by_name(GST_BIN(pipe), "enc");
    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipe), "sink");
    g_signal_connect(sink, "new-sample", G_CALLBACK(on_sample), NULL);
    gst_object_unref(sink);

    loop = g_main_loop_new(NULL, FALSE);
    g_unix_fd_add(0, G_IO_IN | G_IO_HUP | G_IO_ERR, on_stdin, NULL);
    GstBus *bus = gst_element_get_bus(pipe);
    gst_bus_add_watch(bus, on_bus, NULL);
    gst_object_unref(bus);
    g_timeout_add_seconds(1, stats_tick, NULL);

    if (gst_element_set_state(pipe, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        fputs("media: pipeline failed to start\n", stderr);
        return 2;
    }
    pipe_clock = gst_pipeline_get_clock(GST_PIPELINE(pipe));
    fprintf(stderr, "media: pipeline up: %s\n", pipe_str);

    g_main_loop_run(loop);

    gst_element_set_state(pipe, GST_STATE_NULL);
    gst_object_unref(pipe_clock);
    gst_object_unref(pipe);
    if (last_sets)
        g_byte_array_unref(last_sets);
    fprintf(stderr, "media: exit (%u records)\n", n_records);
    return 0;
}
