/* V4L2 access for the host camera layer (camera-host.md §2), written from
 * the public Linux media API documentation (Documentation/userspace-api/
 * media/v4l). Every ioctl is retried on EINTR. Off Linux every call
 * returns -ENOSYS. */
#include "CYcodeCamera.h"

#include <errno.h>
#include <string.h>
#include <time.h>

#if defined(__linux__)
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static int xioctl(int fd, unsigned long request, void *arg) {
    int r;
    do { r = ioctl(fd, request, arg); } while (r < 0 && errno == EINTR);
    return r < 0 ? -errno : 0;
}

int ycam_open(const char *path) {
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

void ycam_close(int fd) {
    if (fd >= 0) close(fd);
}

int ycam_query_caps(int fd, ycam_caps *out) {
    struct v4l2_capability c;
    memset(&c, 0, sizeof c);
    int r = xioctl(fd, VIDIOC_QUERYCAP, &c);
    if (r) return r;
    memset(out, 0, sizeof *out);
    memcpy(out->driver, c.driver, sizeof out->driver);
    memcpy(out->card, c.card, sizeof out->card);
    memcpy(out->bus_info, c.bus_info, sizeof out->bus_info);
    out->driver[sizeof out->driver - 1] = 0;
    out->card[sizeof out->card - 1] = 0;
    out->bus_info[sizeof out->bus_info - 1] = 0;
    out->version = c.version;
    out->capabilities = c.capabilities;
    out->device_caps = (c.capabilities & V4L2_CAP_DEVICE_CAPS) ? c.device_caps : c.capabilities;
    return 0;
}

int ycam_enum_format(int fd, uint32_t index, uint32_t *pixelformat, uint32_t *flags, char description[32]) {
    struct v4l2_fmtdesc d;
    memset(&d, 0, sizeof d);
    d.index = index;
    d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int r = xioctl(fd, VIDIOC_ENUM_FMT, &d);
    if (r) return r;
    *pixelformat = d.pixelformat;
    *flags = d.flags;
    memcpy(description, d.description, 32);
    description[31] = 0;
    return 0;
}

int ycam_enum_framesize(int fd, uint32_t pixelformat, uint32_t index, uint32_t *type, uint32_t v[6]) {
    struct v4l2_frmsizeenum e;
    memset(&e, 0, sizeof e);
    e.index = index;
    e.pixel_format = pixelformat;
    int r = xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &e);
    if (r) return r;
    *type = e.type;
    memset(v, 0, 6 * sizeof v[0]);
    if (e.type == V4L2_FRMSIZE_TYPE_DISCRETE) {
        v[0] = e.discrete.width;
        v[1] = e.discrete.height;
    } else {
        v[0] = e.stepwise.min_width;
        v[1] = e.stepwise.max_width;
        v[2] = e.stepwise.step_width;
        v[3] = e.stepwise.min_height;
        v[4] = e.stepwise.max_height;
        v[5] = e.stepwise.step_height;
    }
    return 0;
}

int ycam_enum_frameinterval(int fd, uint32_t pixelformat, uint32_t width, uint32_t height, uint32_t index,
                            uint32_t *type, uint32_t v[6]) {
    struct v4l2_frmivalenum e;
    memset(&e, 0, sizeof e);
    e.index = index;
    e.pixel_format = pixelformat;
    e.width = width;
    e.height = height;
    int r = xioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, &e);
    if (r) return r;
    *type = e.type;
    memset(v, 0, 6 * sizeof v[0]);
    if (e.type == V4L2_FRMIVAL_TYPE_DISCRETE) {
        v[0] = e.discrete.numerator;
        v[1] = e.discrete.denominator;
    } else {
        v[0] = e.stepwise.min.numerator;
        v[1] = e.stepwise.min.denominator;
        v[2] = e.stepwise.max.numerator;
        v[3] = e.stepwise.max.denominator;
        v[4] = e.stepwise.step.numerator;
        v[5] = e.stepwise.step.denominator;
    }
    return 0;
}

static void from_pix(const struct v4l2_pix_format *p, ycam_format *f) {
    f->width = p->width;
    f->height = p->height;
    f->pixelformat = p->pixelformat;
    f->bytesperline = p->bytesperline;
    f->sizeimage = p->sizeimage;
    f->field = p->field;
    f->colorspace = p->colorspace;
    f->ycbcr_enc = p->ycbcr_enc;
    f->quantization = p->quantization;
    f->xfer_func = p->xfer_func;
}

int ycam_set_format(int fd, ycam_format *f, int try_only) {
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = f->width;
    fmt.fmt.pix.height = f->height;
    fmt.fmt.pix.pixelformat = f->pixelformat;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    int r = xioctl(fd, try_only ? VIDIOC_TRY_FMT : VIDIOC_S_FMT, &fmt);
    if (r) return r;
    from_pix(&fmt.fmt.pix, f);
    return 0;
}

int ycam_get_format(int fd, ycam_format *f) {
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int r = xioctl(fd, VIDIOC_G_FMT, &fmt);
    if (r) return r;
    from_pix(&fmt.fmt.pix, f);
    return 0;
}

int ycam_set_interval(int fd, uint32_t *num, uint32_t *den) {
    struct v4l2_streamparm p;
    memset(&p, 0, sizeof p);
    p.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    int r = xioctl(fd, VIDIOC_G_PARM, &p);
    if (r) return r;
    if (!(p.parm.capture.capability & V4L2_CAP_TIMEPERFRAME)) return -ENOTTY;
    p.parm.capture.timeperframe.numerator = *num;
    p.parm.capture.timeperframe.denominator = *den;
    r = xioctl(fd, VIDIOC_S_PARM, &p);
    if (r) return r;
    *num = p.parm.capture.timeperframe.numerator;
    *den = p.parm.capture.timeperframe.denominator;
    return 0;
}

int ycam_request_buffers(int fd, uint32_t count) {
    struct v4l2_requestbuffers q;
    memset(&q, 0, sizeof q);
    q.count = count;
    q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    q.memory = V4L2_MEMORY_MMAP;
    int r = xioctl(fd, VIDIOC_REQBUFS, &q);
    return r ? r : (int)q.count;
}

int ycam_map_buffer(int fd, uint32_t index, void **address, uint32_t *length) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof b);
    b.index = index;
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    int r = xioctl(fd, VIDIOC_QUERYBUF, &b);
    if (r) return r;
    void *p = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
    if (p == MAP_FAILED) return -errno;
    *address = p;
    *length = b.length;
    return 0;
}

void ycam_unmap_buffer(void *address, uint32_t length) {
    if (address) munmap(address, length);
}

int ycam_queue(int fd, uint32_t index) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof b);
    b.index = index;
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    return xioctl(fd, VIDIOC_QBUF, &b);
}

int ycam_dequeue(int fd, ycam_dequeued *out) {
    struct v4l2_buffer b;
    memset(&b, 0, sizeof b);
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    b.memory = V4L2_MEMORY_MMAP;
    int r = xioctl(fd, VIDIOC_DQBUF, &b);
    if (r) return r;
    out->index = b.index;
    out->bytesused = b.bytesused;
    out->flags = b.flags;
    out->sequence = b.sequence;
    out->timestamp_ns = (int64_t)b.timestamp.tv_sec * 1000000000LL + (int64_t)b.timestamp.tv_usec * 1000LL;
    return 0;
}

int ycam_stream(int fd, int on) {
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    return xioctl(fd, on ? VIDIOC_STREAMON : VIDIOC_STREAMOFF, &type);
}

int ycam_wait(int fd, int timeout_ms) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    int r;
    do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
    if (r < 0) return -errno;
    if (r == 0) return 0;
    if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) return (p.revents & POLLIN) ? 1 : -ENODEV;
    return 1;
}

#else

int ycam_open(const char *path) { (void)path; return -ENOSYS; }
void ycam_close(int fd) { (void)fd; }
int ycam_query_caps(int fd, ycam_caps *out) { (void)fd; (void)out; return -ENOSYS; }
int ycam_enum_format(int fd, uint32_t index, uint32_t *pixelformat, uint32_t *flags, char description[32]) {
    (void)fd; (void)index; (void)pixelformat; (void)flags; (void)description; return -ENOSYS;
}
int ycam_enum_framesize(int fd, uint32_t pixelformat, uint32_t index, uint32_t *type, uint32_t v[6]) {
    (void)fd; (void)pixelformat; (void)index; (void)type; (void)v; return -ENOSYS;
}
int ycam_enum_frameinterval(int fd, uint32_t pixelformat, uint32_t width, uint32_t height, uint32_t index,
                            uint32_t *type, uint32_t v[6]) {
    (void)fd; (void)pixelformat; (void)width; (void)height; (void)index; (void)type; (void)v; return -ENOSYS;
}
int ycam_set_format(int fd, ycam_format *f, int try_only) { (void)fd; (void)f; (void)try_only; return -ENOSYS; }
int ycam_get_format(int fd, ycam_format *f) { (void)fd; (void)f; return -ENOSYS; }
int ycam_set_interval(int fd, uint32_t *num, uint32_t *den) { (void)fd; (void)num; (void)den; return -ENOSYS; }
int ycam_request_buffers(int fd, uint32_t count) { (void)fd; (void)count; return -ENOSYS; }
int ycam_map_buffer(int fd, uint32_t index, void **address, uint32_t *length) {
    (void)fd; (void)index; (void)address; (void)length; return -ENOSYS;
}
void ycam_unmap_buffer(void *address, uint32_t length) { (void)address; (void)length; }
int ycam_queue(int fd, uint32_t index) { (void)fd; (void)index; return -ENOSYS; }
int ycam_dequeue(int fd, ycam_dequeued *out) { (void)fd; (void)out; return -ENOSYS; }
int ycam_stream(int fd, int on) { (void)fd; (void)on; return -ENOSYS; }
int ycam_wait(int fd, int timeout_ms) { (void)fd; (void)timeout_ms; return -ENOSYS; }

#endif

int64_t ycam_monotonic_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}
