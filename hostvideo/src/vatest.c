// vatest (host video): decode a file's video on the host's GPU through VA-API (FFmpeg's hwaccel) and say how fast,
// with a few pixels of one frame read back to show it decoded.
//   vatest FILE [MAXFRAMES]
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <va/va.h>
#include <va/va_vpp.h>
#include <libavutil/pixdesc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static enum AVPixelFormat pick(AVCodecContext *c, const enum AVPixelFormat *f) {
    for (; *f != AV_PIX_FMT_NONE; f++) {
        if (*f == AV_PIX_FMT_VAAPI) {
            return *f;
        }
    }
    fprintf(stderr, "no VA-API format offered\n");
    return AV_PIX_FMT_NONE;
}
// The GPU copies a decoded frame into a linear NV12 surface whose memory is `mem` (a user-pointer surface): no CPU
// touches the pixels. Returns the VA surface, or VA_INVALID_SURFACE.
static VADisplay dpy;
static VAContextID vpp = VA_INVALID_ID;
static int halign = 1;
static VASurfaceID user_surface(void *mem, int w, int h, int stride) {
    uintptr_t ptr = (uintptr_t)mem;
    VASurfaceAttribExternalBuffers ext = {0};
    ext.pixel_format = VA_FOURCC_NV12;
    ext.width = (uint32_t)w, ext.height = (uint32_t)h;
    int ah = (h + halign - 1) / halign * halign;
    ext.data_size = (uint32_t)(((size_t)stride * ah * 3 / 2 + 4095) & ~(size_t)4095);
    ext.num_planes = 2;
    ext.pitches[0] = ext.pitches[1] = (uint32_t)stride;
    ext.offsets[0] = 0, ext.offsets[1] = (uint32_t)(stride * ah);
    ext.buffers = &ptr;
    ext.num_buffers = 1;
    VASurfaceAttrib a[2] = {{VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_SETTABLE, {VAGenericValueTypeInteger, {.i = VA_SURFACE_ATTRIB_MEM_TYPE_USER_PTR}}},
                            {VASurfaceAttribExternalBufferDescriptor, VA_SURFACE_ATTRIB_SETTABLE, {VAGenericValueTypePointer, {.p = &ext}}}};
    VASurfaceID s = VA_INVALID_SURFACE;
    VAStatus st = vaCreateSurfaces(dpy, VA_RT_FORMAT_YUV420, (unsigned)w, (unsigned)h, &s, 1, a, 2);
    if (st != VA_STATUS_SUCCESS) {
        fprintf(stderr, "user-pointer surface: %s\n", vaErrorStr(st));
        return VA_INVALID_SURFACE;
    }
    return s;
}
static int vpp_copy(VASurfaceID from, VASurfaceID to, int w, int h) {
    if (vpp == VA_INVALID_ID) {
        VAConfigID cfg;
        if (vaCreateConfig(dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0, &cfg) != VA_STATUS_SUCCESS ||
            vaCreateContext(dpy, cfg, w, h, VA_PROGRESSIVE, NULL, 0, &vpp) != VA_STATUS_SUCCESS) {
            fprintf(stderr, "no video processing context\n");
            return -1;
        }
    }
    if (getenv("VATEST_VACOPY")) {   // vaCopy: a plain copy (the copy engine), no scaler
        VACopyObject d = {.obj_type = VACopyObjectSurface, .object = {.surface_id = to}};
        VACopyObject sobj = {.obj_type = VACopyObjectSurface, .object = {.surface_id = from}};
        VACopyOption o = {.bits = {.va_copy_sync = VA_EXEC_SYNC, .va_copy_mode = (uint32_t)atoi(getenv("VATEST_VACOPY"))}};
        VAStatus cs = vaCopy(dpy, &d, &sobj, o);
        if (cs == VA_STATUS_SUCCESS) cs = vaSyncSurface(dpy, to);
        if (cs != VA_STATUS_SUCCESS) fprintf(stderr, "vaCopy: %s\n", vaErrorStr(cs));
        return cs == VA_STATUS_SUCCESS ? 0 : -1;
    }
    VAProcPipelineParameterBuffer pp = {0};
    pp.surface = from;
    pp.filter_flags = getenv("VATEST_VPPFLAGS") ? (unsigned)strtoul(getenv("VATEST_VPPFLAGS"), NULL, 0) : 0;
    VABufferID b;
    if (vaCreateBuffer(dpy, vpp, VAProcPipelineParameterBufferType, sizeof(pp), 1, &pp, &b) != VA_STATUS_SUCCESS) {
        return -1;
    }
    VAStatus st = vaBeginPicture(dpy, vpp, to);
    if (st == VA_STATUS_SUCCESS) st = vaRenderPicture(dpy, vpp, &b, 1);
    if (st == VA_STATUS_SUCCESS) st = vaEndPicture(dpy, vpp);
    if (st == VA_STATUS_SUCCESS) st = vaSyncSurface(dpy, to);
    vaDestroyBuffer(dpy, b);
    return st == VA_STATUS_SUCCESS ? 0 : -1;
}
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "vatest FILE [MAXFRAMES]\n");
        return 2;
    }
    int maxf = argc > 2 ? atoi(argv[2]) : 1 << 30;
    AVFormatContext *fc = NULL;
    if (avformat_open_input(&fc, argv[1], NULL, NULL) < 0 || avformat_find_stream_info(fc, NULL) < 0) {
        fprintf(stderr, "can't open %s\n", argv[1]);
        return 1;
    }
    int si = av_find_best_stream(fc, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    AVStream *st = fc->streams[si];
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *c = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(c, st->codecpar);
    AVBufferRef *dev = NULL;
    int rc = av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VAAPI, "/dev/dri/renderD128", NULL, 0);
    if (rc < 0) {
        fprintf(stderr, "VA-API device: %s\n", av_err2str(rc));
        return 1;
    }
    c->hw_device_ctx = av_buffer_ref(dev);
    c->get_format = pick;
    if ((rc = avcodec_open2(c, codec, NULL)) < 0) {
        fprintf(stderr, "open decoder: %s\n", av_err2str(rc));
        return 1;
    }
    printf("%s %dx%d, decoder %s\n", argv[1], c->width, c->height, codec->name);
    AVPacket *p = av_packet_alloc();
    AVFrame *f = av_frame_alloc(), *sw = av_frame_alloc();
    int n = 0, shown = 0, ndl = 0;
    double t0 = now(), dl = 0;
    int dl_every = getenv("VATEST_DOWNLOAD") ? 1 : 0, use_vpp = getenv("VATEST_VPP") ? 1 : 0;
    dpy = ((AVVAAPIDeviceContext *)((AVHWDeviceContext *)dev->data)->hwctx)->display;
    int stride = (c->width + 127) & ~127;
    uint8_t *mem = NULL;
    VASurfaceID us = VA_INVALID_SURFACE;
    if (use_vpp) {
        halign = getenv("VATEST_HALIGN") ? atoi(getenv("VATEST_HALIGN")) : 1;
        if (getenv("VATEST_STRIDE")) {
            stride = atoi(getenv("VATEST_STRIDE"));
        }
        posix_memalign((void **)&mem, 4096, (size_t)stride * ((c->height + 63) & ~63) * 3 / 2 + 8192);
        us = user_surface(mem, c->width, c->height, stride);
    }
    while (n < maxf && av_read_frame(fc, p) >= 0) {
        if (p->stream_index == si && avcodec_send_packet(c, p) >= 0) {
            while (avcodec_receive_frame(c, f) >= 0) {
                n++;
                if (getenv("VATEST_LUMA")) {   // "X,Y": that pixel's luma in every frame, to compare with a software decode
                    int x = atoi(getenv("VATEST_LUMA")), yy = atoi(strchr(getenv("VATEST_LUMA"), ',') + 1);
                    av_frame_unref(sw);
                    if (av_hwframe_transfer_data(sw, f, 0) >= 0) {
                        printf("luma %d %u\n", n - 1, sw->data[0][yy * sw->linesize[0] + x]);
                    }
                }
                if (!shown && n == 10) {
                    shown = 1;
                    if (av_hwframe_transfer_data(sw, f, 0) >= 0) {
                        const uint8_t *y = sw->data[0];
                        int l = sw->linesize[0];
                        printf("frame 10 on the host: %s %dx%d, luma %u %u %u %u\n",
                               av_get_pix_fmt_name(sw->format), sw->width, sw->height, y[0], y[sw->width / 2],
                               y[(sw->height / 2) * l + sw->width / 2], y[(sw->height - 1) * l + sw->width - 1]);
                    }
                }
                if (use_vpp && us != VA_INVALID_SURFACE) {
                    double d0 = now();
                    int rc = vpp_copy((VASurfaceID)(uintptr_t)f->data[3], us, c->width, c->height);
                    dl += now() - d0, ndl++;
                    if (getenv("VATEST_LUMA")) {
                        int x = atoi(getenv("VATEST_LUMA")), yy = atoi(strchr(getenv("VATEST_LUMA"), ',') + 1);
                        printf("vpp luma %d %u\n", n - 1, mem[(size_t)yy * stride + x]);
                    }
                    if (n == 10) {
                        printf("frame 10 by the GPU into memory: %s, luma %u %u %u %u\n", rc ? "FAILED" : "ok", mem[0],
                               mem[c->width / 2], mem[(size_t)(c->height / 2) * stride + c->width / 2],
                               mem[(size_t)(c->height - 1) * stride + c->width - 1]);
                    }
                }
                if (dl_every) {   // the copy off the GPU, as venera-videod does for each frame
                    double d0 = now();
                    av_frame_unref(sw);
                    av_hwframe_transfer_data(sw, f, 0);
                    dl += now() - d0, ndl++;
                }
                av_frame_unref(f);
            }
        }
        av_packet_unref(p);
    }
    avcodec_send_packet(c, NULL);
    while (avcodec_receive_frame(c, f) >= 0) {
        n++;
        av_frame_unref(f);
    }
    double s = now() - t0;
    printf("%d frames in %.2f s: %.0f fps on the GPU\n", n, s, n / s);
    if (ndl) {
        printf("copy off the GPU: %.2f ms a frame (%d frames)\n", dl * 1000 / ndl, ndl);
    }
    return 0;
}
