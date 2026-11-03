/* CYcodeOpenXR: the OpenXR side of Ycode's headset viewer
 * (specs/simulator/xr-viewer.md).
 *
 * - Opens the Khronos OpenXR loader (libopenxr_loader.so.1, Apache-2.0) and
 *   the Vulkan loader (libvulkan.so.1) at run time with dlopen; nothing links
 *   against either, so macOS and hosts without them build and report that
 *   OpenXR is unavailable. No runtime (WiVRn, Monado, ...) is linked: the
 *   loader finds the active runtime itself.
 * - One session with a Vulkan graphics binding (XR_KHR_vulkan_enable2) on
 *   the GPU the runtime names; per eye one swapchain that takes BGRA images
 *   from host memory; a projection layer per frame whose views carry the
 *   pose and field of view each image was rendered for.
 * - Tracking each frame: the views, the head (VIEW space), the eye gaze
 *   (XR_EXT_eye_gaze_interaction), both hands' joints (XR_EXT_hand_tracking),
 *   controller aim and grip poses, trigger, squeeze, thumbstick and buttons.
 *
 * Interfaces from the vendored Khronos headers (include/openxr: openxr.h,
 * openxr_platform.h, openxr_platform_defines.h of OpenXR-SDK release-1.1.47,
 * SPDX "Apache-2.0 OR MIT", Copyright The Khronos Group Inc.) and the
 * Vulkan headers of the CVulkan target (Apache-2.0).
 *
 * Privacy: eye-gaze poses are handed to the caller and never logged here. */
#ifndef CYCODE_OPENXR_H
#define CYCODE_OPENXR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { float x, y, z; } yxr_vec3;
typedef struct { float x, y, z, w; } yxr_quat;
typedef struct { yxr_vec3 position; yxr_quat orientation; } yxr_pose;
/* Angles in radians, as OpenXR's XrFovf: left and down are negative for a
 * view centred on its axis. */
typedef struct { float angle_left, angle_right, angle_up, angle_down; } yxr_fov;

enum { YXR_JOINTS = 26 };   /* XR_HAND_JOINT_COUNT_EXT */

typedef struct {
    char runtime[128];
    uint32_t runtime_version;           /* XR_MAKE_VERSION */
    char system_name[256];
    uint32_t vendor_id;
    /* extensions offered by the runtime (1/0) */
    int has_eye_gaze, has_hand_tracking, has_hand_interaction, has_fb_eye_social, has_touch_pro;
    /* what the system supports (after enabling) */
    int eye_gaze_supported, hand_tracking_supported;
    uint32_t view_count;
    uint32_t recommended_width[2], recommended_height[2], max_width[2], max_height[2];
    uint32_t max_layers;
    char gpu_name[256];
    uint32_t gpu_vendor;
    int64_t swapchain_format;           /* the VkFormat chosen (0 before a session) */
    int swapchain_bgra;                 /* 1: B8G8R8A8 (no swizzle needed) */
    int space;                          /* 1 STAGE, 2 LOCAL (the base space) */
    int blend_modes;                    /* bit (1 << XrEnvironmentBlendMode) */
    char extensions[4096];              /* every offered extension, space-separated */
} yxr_info;

typedef struct {
    int64_t display_time;               /* predicted display time (XrTime, ns) */
    int64_t display_period;
    int should_render;
    int focused;                        /* actions are live */
    int views_valid;
    yxr_pose view_pose[2];
    yxr_fov view_fov[2];
    int head_valid;
    yxr_pose head;                      /* VIEW space in the base space */
    int gaze_valid;
    yxr_pose gaze;                      /* the eye-gaze pose (−Z = the gaze direction) */
    int64_t gaze_time;                  /* its sample time, 0 if not given */
    int gaze_tracked;                   /* the runtime says the orientation is tracked now (else inferred or held) */
    int hand_valid[2];                  /* 0 left, 1 right */
    yxr_pose joint[2][YXR_JOINTS];
    float joint_radius[2][YXR_JOINTS];
    uint32_t joint_valid[2];            /* bit j: joint j's position and orientation valid */
    int aim_valid[2], grip_valid[2];
    yxr_pose aim[2], grip[2];
    float trigger[2], squeeze[2], stick_x[2], stick_y[2];
    int stick_click[2];
    int button_lower[2];                /* A (right) / X (left) */
    int button_upper[2];                /* B (right) / Y (left) */
    int button_menu;                    /* left menu button */
    int controller_active[2];           /* the hand's current profile is a controller */
    int hand_profile_active[2];         /* the hand's current profile is hand interaction */
} yxr_frame;

enum {
    YXR_EVENT_NONE = 0,
    YXR_EVENT_STATE = 1,                /* value = XrSessionState */
    YXR_EVENT_RECENTER = 2,             /* the base space was recentred (value = space type) */
    YXR_EVENT_PROFILE = 3,              /* an interaction profile changed */
    YXR_EVENT_EXIT = 4,                 /* the session ended (exit or loss) */
    YXR_EVENT_LOST = 5,
};

typedef struct { int kind; int64_t value; } yxr_event;

typedef struct yxr_session yxr_session;

/* 1 when the loader opens (the reason in `error` otherwise). */
int yxr_available(char *error, size_t error_size);

/* Creates the instance and the system and fills `info`. `session` 0 stops
 * there (no Vulkan, no session); 1 also creates the Vulkan device and the
 * session (stage space, falling back to local). May block while the runtime
 * waits for a headset (WiVRn does). NULL on failure. */
yxr_session *yxr_open(const char *app_name, int session, yxr_info *info, char *error, size_t error_size);

/* One pending event, or 0. Begins and ends the session on READY and
 * STOPPING itself. */
int yxr_poll(yxr_session *s, yxr_event *event);

/* 1 while the session runs (between begin and end). */
int yxr_running(yxr_session *s);

/* xrWaitFrame + xrBeginFrame, then the tracking for the frame's predicted
 * display time. 0 on success. */
int yxr_begin_frame(yxr_session *s, yxr_frame *frame);

/* Copies a BGRA image (rows of `stride` bytes) into eye `eye`'s swapchain
 * (0 left, 1 right; 2 and 3: the hands' layers; 4 and 5: the foveal insets;
 * 10: the mono picture, 11: its inset; 12 and 13: the gaze reticle and a calibration target),
 * recreating it at width x height when the size changed.
 * Call between begin and end frame. 0 on success. */
int yxr_upload(yxr_session *s, int eye, const void *bgra, int width, int height, int stride);

/* The same from an NV12 picture (a video frame: luma rows of `pitch`
 * bytes, then interleaved chroma at half height), converted to BGRA
 * (BT.601 limited range) on several threads straight into the staging
 * buffer. 0 on success. */
int yxr_upload_nv12(yxr_session *s, int eye, const uint8_t *y, const uint8_t *uv, int pitch, int width, int height);

/* The same from a planar 4:4:4 picture (HEVC 4:4:4), BT.709 limited range. */
int yxr_upload_yuv444(yxr_session *s, int eye, const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height);

/* That conversion without a session (offscreen replay and tests): into `dst`,
 * width * 4 bytes a row, on several threads; `bgra` 0: red first. */
void yxr_convert_yuv444(const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height, uint8_t *dst, int bgra);
/* And from NV12. */
void yxr_convert_nv12(const uint8_t *y, const uint8_t *uv, int pitch, int width, int height, uint8_t *dst, int bgra);

/* 1: the gaze is located at the present (the newest the runtime has) rather than
 * at the frame's predicted display time, ahead of it. */
void yxr_set_gaze_at_present(yxr_session *s, int on);

/* A camera-facing sprite drawn over the picture (the rendered hands):
 * a quad of `size` metres at `pose` (base space; its +Z faces the viewer)
 * showing image `image` (2, 3, 12 or 13: images uploaded with yxr_upload
 * into those slots), blended by the image's alpha. */
typedef struct { yxr_pose pose; float size; int image; } yxr_sprite;

enum { YXR_MAX_SPRITES = 120 };

typedef struct {
    int submit;                         /* 0: no projection layer this frame (black) */
    int image[2];                       /* the swapchain (0, 1 or 10) each view shows; -1 = nothing yet */
    yxr_pose pose[2];                   /* the pose each view's image was rendered for (base space) */
    yxr_fov fov[2];                     /* and its field of view */
    /* Hooks for a reprojecting renderer (XR-DEPTH): render[i] 1 = view i
     * shows the rendered swapchain of eye i (yxr_acquire_render) instead of
     * `image[i]`, at `pose[i]` and `fov[i]` (the caller passes the current
     * eye pose and full field of view); the inset layer is then left out.
     * depth_valid[i] 1 = chain the eye's depth swapchain
     * (XR_KHR_composition_layer_depth, when offered) with near/far
     * (reverse Z: min depth 0, max 1, near_z 0.1, far_z large). */
    int render[2];
    int depth_valid[2];
    float depth_near, depth_far;
    /* Foveated streaming: a second projection layer over the first, view i
     * showing swapchain `inset_image[i]` (4, 5 or 11) with `inset_fov[i]` at
     * the same pose, blended by its alpha (a soft edge). */
    int inset;
    int inset_image[2];
    yxr_fov inset_fov[2];
    const yxr_sprite *sprites;          /* drawn over the projection layers (may be NULL) */
    int sprite_count;
} yxr_submit;

/* xrEndFrame with one projection layer (or none). 0 on success. */
int yxr_end_frame(yxr_session *s, const yxr_submit *submit);

/* Asks the runtime to end the session (xrRequestExitSession). */
void yxr_request_exit(yxr_session *s);

/* Destroys everything. */
void yxr_close(yxr_session *s);

/* The Vulkan objects of the session (hook a), as integers/pointers so
 * this header needs no Vulkan types. */
typedef struct {
    void *instance;                     /* VkInstance */
    void *physical_device;              /* VkPhysicalDevice */
    void *device;                       /* VkDevice */
    uint32_t queue_family;
    void *queue;                        /* VkQueue */
    void *get_instance_proc_addr;       /* PFN_vkGetInstanceProcAddr */
    int64_t color_format;               /* the swapchains' VkFormat */
    uint32_t recommended_width, recommended_height;
    int anisotropy;                     /* the device has samplerAnisotropy enabled */
} yxr_vulkan_handles;

/* 0 on success (after a session was created). */
int yxr_vulkan(yxr_session *s, yxr_vulkan_handles *out);

/* Hook b: eye `eye`'s rendered swapchain at the recommended size, made on
 * first use; acquires and waits for its next image (a VkImage, as an
 * integer, in COLOR_ATTACHMENT_OPTIMAL when released). Between begin and
 * end frame. 0 on success. */
int yxr_acquire_render(yxr_session *s, int eye, uint64_t *image, int *width, int *height, int64_t *format);
int yxr_release_render(yxr_session *s, int eye);

/* Hook c: the same for the eye's depth swapchain (D32_SFLOAT) when the
 * runtime offers XR_KHR_composition_layer_depth; -1 otherwise. */
int yxr_has_depth_layers(yxr_session *s);
int yxr_acquire_depth(yxr_session *s, int eye, uint64_t *image, int *width, int *height, int64_t *format);
int yxr_release_depth(yxr_session *s, int eye);

/* The session's queue is shared: anyone submitting to it holds this lock
 * (the uploads here take it too). */
void yxr_queue_lock(yxr_session *s);
void yxr_queue_unlock(yxr_session *s);

/* The runtime's time (XrTime, ns) for CLOCK_MONOTONIC now, through
 * XR_KHR_convert_timespec_time; 0 when the runtime does not offer it. */
int64_t yxr_now(yxr_session *s);

/* The last error text of this session. */
const char *yxr_last_error(yxr_session *s);

#ifdef __cplusplus
}
#endif

#endif
