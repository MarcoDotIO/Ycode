/* CYcodeOpenXR: see include/CYcodeOpenXR.h and specs/simulator/xr-viewer.md.
 * Written from the OpenXR 1.1 specification and registry (Khronos, public)
 * and the Vulkan 1.3 specification. */
#include "CYcodeOpenXR.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__)

#include <dlfcn.h>
#include <pthread.h>
#include <time.h>

#define VK_NO_PROTOTYPES 1
#include "../../CVulkan/vulkan/vulkan_core.h"
#define XR_NO_PROTOTYPES 1
#define XR_USE_GRAPHICS_API_VULKAN 1
#define XR_USE_TIMESPEC 1
#include "openxr/openxr.h"
#include "openxr/openxr_platform.h"

static void *xr_lib;
static PFN_xrGetInstanceProcAddr p_xrGetInstanceProcAddr;
static void *vk_lib;
static PFN_vkGetInstanceProcAddr p_vkGetInstanceProcAddr;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;
static char load_error[256];

static void load_libraries(void) {
    const char *xr = getenv("YCODE_OPENXR_LOADER");
    const char *names[] = { xr, "libopenxr_loader.so.1", "libopenxr_loader.so" };
    for (size_t i = 0; i < sizeof names / sizeof *names && !xr_lib; i++)
        if (names[i]) xr_lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!xr_lib) { snprintf(load_error, sizeof load_error, "the OpenXR loader (libopenxr_loader.so.1) is not installed"); return; }
    p_xrGetInstanceProcAddr = (PFN_xrGetInstanceProcAddr)dlsym(xr_lib, "xrGetInstanceProcAddr");
    if (!p_xrGetInstanceProcAddr) { snprintf(load_error, sizeof load_error, "xrGetInstanceProcAddr missing in the loader"); return; }
    vk_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (vk_lib) p_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(vk_lib, "vkGetInstanceProcAddr");
}

int yxr_available(char *error, size_t error_size) {
    pthread_once(&load_once, load_libraries);
    if (!p_xrGetInstanceProcAddr) { if (error && error_size) snprintf(error, error_size, "%s", load_error); return 0; }
    return 1;
}

/* The OpenXR and Vulkan functions this file calls. */
#define XR_FUNCS(X) \
    X(xrDestroyInstance) X(xrGetInstanceProperties) X(xrGetSystem) X(xrGetSystemProperties) \
    X(xrEnumerateViewConfigurationViews) X(xrEnumerateEnvironmentBlendModes) X(xrCreateSession) X(xrDestroySession) \
    X(xrBeginSession) X(xrEndSession) X(xrRequestExitSession) X(xrPollEvent) X(xrResultToString) \
    X(xrEnumerateSwapchainFormats) X(xrCreateSwapchain) X(xrDestroySwapchain) X(xrEnumerateSwapchainImages) \
    X(xrAcquireSwapchainImage) X(xrWaitSwapchainImage) X(xrReleaseSwapchainImage) \
    X(xrCreateReferenceSpace) X(xrDestroySpace) X(xrLocateSpace) X(xrLocateViews) \
    X(xrWaitFrame) X(xrBeginFrame) X(xrEndFrame) X(xrStringToPath) X(xrPathToString) \
    X(xrCreateActionSet) X(xrDestroyActionSet) X(xrCreateAction) X(xrSuggestInteractionProfileBindings) \
    X(xrAttachSessionActionSets) X(xrCreateActionSpace) X(xrSyncActions) X(xrGetActionStateFloat) \
    X(xrGetActionStateBoolean) X(xrGetActionStateVector2f) X(xrGetCurrentInteractionProfile)

#define VK_IFUNCS(X) \
    X(vkDestroyInstance) X(vkGetPhysicalDeviceProperties) X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceFeatures) X(vkGetDeviceProcAddr) X(vkDestroyDevice)
#define VK_DFUNCS(X) \
    X(vkGetDeviceQueue) X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
    X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCmdPipelineBarrier) X(vkCmdCopyBufferToImage) \
    X(vkQueueSubmit) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
    X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkFreeMemory) \
    X(vkBindBufferMemory) X(vkMapMemory) X(vkUnmapMemory) X(vkDeviceWaitIdle) X(vkResetCommandBuffer)

typedef struct {
    XrSwapchain handle;
    uint32_t width, height, count;
    VkImage images[8];
    VkBuffer staging;
    VkDeviceMemory staging_memory;
    void *staging_map;
    size_t staging_size;
    VkCommandBuffer cmd;
    VkFence fence;
    int fence_pending;
    int released_once;
} eye_chain;

struct yxr_session {
    XrInstance instance;
    XrSystemId system;
    XrSession session;
    int running, state, exit_requested;
    XrSpace base, view;
    int space_type;
    XrActionSet actions;
    XrAction gaze, aim, grip, trigger, squeeze, stick, stick_click, lower, upper, menu;
    XrSpace gaze_space, aim_space[2], grip_space[2];
    XrPath hands[2];
    XrHandTrackerEXT trackers[2];
    PFN_xrCreateHandTrackerEXT create_tracker;
    PFN_xrDestroyHandTrackerEXT destroy_tracker;
    PFN_xrLocateHandJointsEXT locate_joints;
    PFN_xrConvertTimespecTimeToTimeKHR convert_time;
    int eye_gaze, hand_tracking, hand_interaction, touch_pro;
    int gaze_at_present;
    XrFrameState frame_state;
    int in_frame;
    /* Vulkan */
    VkInstance vk_instance;
    VkPhysicalDevice vk_physical;
    VkDevice vk_device;
    VkQueue vk_queue;
    uint32_t vk_queue_family;
    VkCommandPool vk_pool;
    VkPhysicalDeviceMemoryProperties vk_memory;
    int vk_anisotropy;
    int64_t format;
    int format_bgra;
    eye_chain eye[14];                  /* 0, 1: the eyes; 2, 3: sprite images; 4, 5: foveal insets;
                                           6, 7: rendered (hook b); 8, 9: depth (hook c);
                                           10: the mono picture, 11: its inset */
    pthread_mutex_t queue_lock;
    int depth_ext;
    uint32_t rec_w, rec_h;
    char error[512];
#define DECL(f) PFN_##f f;
    XR_FUNCS(DECL)
    VK_IFUNCS(DECL)
    VK_DFUNCS(DECL)
#undef DECL
};

static void set_error(yxr_session *s, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(s->error, sizeof s->error, fmt, ap);
    va_end(ap);
}

static const char *xr_text(yxr_session *s, XrResult r) {
    static __thread char b[XR_MAX_RESULT_STRING_SIZE];
    snprintf(b, sizeof b, "%d", r);
    if (s->instance && s->xrResultToString) s->xrResultToString(s->instance, r, b);
    return b;
}

#define XR_CHECK(s, call) do { XrResult r_ = (call); if (XR_FAILED(r_)) { set_error((s), "%s: %s", #call, xr_text((s), r_)); goto fail; } } while (0)

const char *yxr_last_error(yxr_session *s) { return s ? s->error : load_error; }

static XrPath path(yxr_session *s, const char *p) {
    XrPath x = XR_NULL_PATH;
    s->xrStringToPath(s->instance, p, &x);
    return x;
}

static int has_extension(const XrExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++) if (!strcmp(e[i].extensionName, name)) return 1;
    return 0;
}

static void suggest(yxr_session *s, const char *profile, const XrActionSuggestedBinding *b, uint32_t n) {
    XrInteractionProfileSuggestedBinding sb = { XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING };
    sb.interactionProfile = path(s, profile);
    sb.countSuggestedBindings = n;
    sb.suggestedBindings = b;
    s->xrSuggestInteractionProfileBindings(s->instance, &sb);   /* an unknown profile is not fatal */
}

static int make_action(yxr_session *s, XrAction *a, XrActionType type, const char *name, const char *label, int per_hand) {
    XrActionCreateInfo ci = { XR_TYPE_ACTION_CREATE_INFO };
    ci.actionType = type;
    snprintf(ci.actionName, sizeof ci.actionName, "%s", name);
    snprintf(ci.localizedActionName, sizeof ci.localizedActionName, "%s", label);
    if (per_hand) { ci.countSubactionPaths = 2; ci.subactionPaths = s->hands; }
    XrResult r = s->xrCreateAction(s->actions, &ci, a);
    if (XR_FAILED(r)) { set_error(s, "xrCreateAction %s: %s", name, xr_text(s, r)); return -1; }
    return 0;
}

static int setup_actions(yxr_session *s) {
    XrActionSetCreateInfo ai = { XR_TYPE_ACTION_SET_CREATE_INFO };
    snprintf(ai.actionSetName, sizeof ai.actionSetName, "ycode");
    snprintf(ai.localizedActionSetName, sizeof ai.localizedActionSetName, "Ycode simulator");
    if (XR_FAILED(s->xrCreateActionSet(s->instance, &ai, &s->actions))) { set_error(s, "xrCreateActionSet failed"); return -1; }
    s->hands[0] = path(s, "/user/hand/left");
    s->hands[1] = path(s, "/user/hand/right");
    if (s->eye_gaze && make_action(s, &s->gaze, XR_ACTION_TYPE_POSE_INPUT, "gaze", "Gaze", 0)) return -1;
    if (make_action(s, &s->aim, XR_ACTION_TYPE_POSE_INPUT, "aim", "Aim", 1)
        || make_action(s, &s->grip, XR_ACTION_TYPE_POSE_INPUT, "grip", "Grip", 1)
        || make_action(s, &s->trigger, XR_ACTION_TYPE_FLOAT_INPUT, "select", "Select", 1)
        || make_action(s, &s->squeeze, XR_ACTION_TYPE_FLOAT_INPUT, "squeeze", "Squeeze", 1)
        || make_action(s, &s->stick, XR_ACTION_TYPE_VECTOR2F_INPUT, "stick", "Thumbstick", 1)
        || make_action(s, &s->stick_click, XR_ACTION_TYPE_BOOLEAN_INPUT, "stick_click", "Thumbstick click", 1)
        || make_action(s, &s->lower, XR_ACTION_TYPE_BOOLEAN_INPUT, "lower_button", "A or X", 1)
        || make_action(s, &s->upper, XR_ACTION_TYPE_BOOLEAN_INPUT, "upper_button", "B or Y", 1)
        || make_action(s, &s->menu, XR_ACTION_TYPE_BOOLEAN_INPUT, "menu", "Menu", 0)) return -1;
    if (s->eye_gaze) {
        XrActionSuggestedBinding b[] = { { s->gaze, path(s, "/user/eyes_ext/input/gaze_ext/pose") } };
        suggest(s, "/interaction_profiles/ext/eye_gaze_interaction", b, 1);
    }
    {
        XrActionSuggestedBinding b[] = {
            { s->aim, path(s, "/user/hand/left/input/aim/pose") }, { s->aim, path(s, "/user/hand/right/input/aim/pose") },
            { s->grip, path(s, "/user/hand/left/input/grip/pose") }, { s->grip, path(s, "/user/hand/right/input/grip/pose") },
            { s->trigger, path(s, "/user/hand/left/input/trigger/value") }, { s->trigger, path(s, "/user/hand/right/input/trigger/value") },
            { s->squeeze, path(s, "/user/hand/left/input/squeeze/value") }, { s->squeeze, path(s, "/user/hand/right/input/squeeze/value") },
            { s->stick, path(s, "/user/hand/left/input/thumbstick") }, { s->stick, path(s, "/user/hand/right/input/thumbstick") },
            { s->stick_click, path(s, "/user/hand/left/input/thumbstick/click") }, { s->stick_click, path(s, "/user/hand/right/input/thumbstick/click") },
            { s->lower, path(s, "/user/hand/left/input/x/click") }, { s->lower, path(s, "/user/hand/right/input/a/click") },
            { s->upper, path(s, "/user/hand/left/input/y/click") }, { s->upper, path(s, "/user/hand/right/input/b/click") },
            { s->menu, path(s, "/user/hand/left/input/menu/click") },
        };
        uint32_t n = sizeof b / sizeof *b;
        suggest(s, "/interaction_profiles/oculus/touch_controller", b, n);
        if (s->touch_pro) suggest(s, "/interaction_profiles/facebook/touch_controller_pro", b, n);
    }
    {
        XrActionSuggestedBinding b[] = {
            { s->aim, path(s, "/user/hand/left/input/aim/pose") }, { s->aim, path(s, "/user/hand/right/input/aim/pose") },
            { s->grip, path(s, "/user/hand/left/input/grip/pose") }, { s->grip, path(s, "/user/hand/right/input/grip/pose") },
            { s->trigger, path(s, "/user/hand/left/input/select/click") }, { s->trigger, path(s, "/user/hand/right/input/select/click") },
            { s->menu, path(s, "/user/hand/left/input/menu/click") },
        };
        suggest(s, "/interaction_profiles/khr/simple_controller", b, sizeof b / sizeof *b);
    }
    if (s->hand_interaction) {
        /* Pinch comes from the joints (hysteresis in the viewer); the
         * profile gives the runtime's aim ray for hands. */
        XrActionSuggestedBinding b[] = {
            { s->aim, path(s, "/user/hand/left/input/aim/pose") }, { s->aim, path(s, "/user/hand/right/input/aim/pose") },
            { s->grip, path(s, "/user/hand/left/input/grip/pose") }, { s->grip, path(s, "/user/hand/right/input/grip/pose") },
        };
        suggest(s, "/interaction_profiles/ext/hand_interaction_ext", b, sizeof b / sizeof *b);
    }
    return 0;
}

static int session_spaces_and_actions(yxr_session *s) {
    XrSessionActionSetsAttachInfo at = { XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO };
    at.countActionSets = 1;
    at.actionSets = &s->actions;
    XR_CHECK(s, s->xrAttachSessionActionSets(s->session, &at));
    XrActionSpaceCreateInfo as = { XR_TYPE_ACTION_SPACE_CREATE_INFO };
    as.poseInActionSpace.orientation.w = 1;
    if (s->eye_gaze) { as.action = s->gaze; XR_CHECK(s, s->xrCreateActionSpace(s->session, &as, &s->gaze_space)); }
    for (int h = 0; h < 2; h++) {
        as.subactionPath = s->hands[h];
        as.action = s->aim; XR_CHECK(s, s->xrCreateActionSpace(s->session, &as, &s->aim_space[h]));
        as.action = s->grip; XR_CHECK(s, s->xrCreateActionSpace(s->session, &as, &s->grip_space[h]));
    }
    if (s->hand_tracking) {
        p_xrGetInstanceProcAddr(s->instance, "xrCreateHandTrackerEXT", (PFN_xrVoidFunction *)&s->create_tracker);
        p_xrGetInstanceProcAddr(s->instance, "xrDestroyHandTrackerEXT", (PFN_xrVoidFunction *)&s->destroy_tracker);
        p_xrGetInstanceProcAddr(s->instance, "xrLocateHandJointsEXT", (PFN_xrVoidFunction *)&s->locate_joints);
        for (int h = 0; h < 2 && s->create_tracker; h++) {
            XrHandTrackerCreateInfoEXT hc = { XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT };
            hc.hand = h ? XR_HAND_RIGHT_EXT : XR_HAND_LEFT_EXT;
            hc.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
            if (XR_FAILED(s->create_tracker(s->session, &hc, &s->trackers[h]))) s->trackers[h] = XR_NULL_HANDLE;
        }
    }
    return 0;
fail:
    return -1;
}

static int vk_setup(yxr_session *s, yxr_info *info) {
    if (!p_vkGetInstanceProcAddr) { set_error(s, "the Vulkan loader (libvulkan.so.1) is not installed"); return -1; }
    PFN_xrGetVulkanGraphicsRequirements2KHR req;
    PFN_xrCreateVulkanInstanceKHR create_instance;
    PFN_xrGetVulkanGraphicsDevice2KHR get_device;
    PFN_xrCreateVulkanDeviceKHR create_device;
    XR_CHECK(s, p_xrGetInstanceProcAddr(s->instance, "xrGetVulkanGraphicsRequirements2KHR", (PFN_xrVoidFunction *)&req));
    XR_CHECK(s, p_xrGetInstanceProcAddr(s->instance, "xrCreateVulkanInstanceKHR", (PFN_xrVoidFunction *)&create_instance));
    XR_CHECK(s, p_xrGetInstanceProcAddr(s->instance, "xrGetVulkanGraphicsDevice2KHR", (PFN_xrVoidFunction *)&get_device));
    XR_CHECK(s, p_xrGetInstanceProcAddr(s->instance, "xrCreateVulkanDeviceKHR", (PFN_xrVoidFunction *)&create_device));
    XrGraphicsRequirementsVulkan2KHR gr = { XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR };
    XR_CHECK(s, req(s->instance, s->system, &gr));
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "ycode-xr-viewer";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    XrVulkanInstanceCreateInfoKHR xi = { XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR };
    xi.systemId = s->system;
    xi.pfnGetInstanceProcAddr = p_vkGetInstanceProcAddr;
    xi.vulkanCreateInfo = &ici;
    VkResult vr = VK_SUCCESS;
    XR_CHECK(s, create_instance(s->instance, &xi, &s->vk_instance, &vr));
    if (vr != VK_SUCCESS) { set_error(s, "vkCreateInstance: %d", vr); return -1; }
#define LOADI(f) s->f = (PFN_##f)p_vkGetInstanceProcAddr(s->vk_instance, #f); if (!s->f) { set_error(s, "Vulkan: %s missing", #f); return -1; }
    VK_IFUNCS(LOADI)
#undef LOADI
    XrVulkanGraphicsDeviceGetInfoKHR gi = { XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR };
    gi.systemId = s->system;
    gi.vulkanInstance = s->vk_instance;
    XR_CHECK(s, get_device(s->instance, &gi, &s->vk_physical));
    VkPhysicalDeviceProperties pp;
    s->vkGetPhysicalDeviceProperties(s->vk_physical, &pp);
    snprintf(info->gpu_name, sizeof info->gpu_name, "%s", pp.deviceName);
    info->gpu_vendor = pp.vendorID;
    s->vkGetPhysicalDeviceMemoryProperties(s->vk_physical, &s->vk_memory);
    uint32_t nq = 0;
    s->vkGetPhysicalDeviceQueueFamilyProperties(s->vk_physical, &nq, NULL);
    VkQueueFamilyProperties qf[32];
    if (nq > 32) nq = 32;
    s->vkGetPhysicalDeviceQueueFamilyProperties(s->vk_physical, &nq, qf);
    s->vk_queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++) if (qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { s->vk_queue_family = i; break; }
    if (s->vk_queue_family == UINT32_MAX) { set_error(s, "no graphics queue"); return -1; }
    float prio = 1;
    VkDeviceQueueCreateInfo qi = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qi.queueFamilyIndex = s->vk_queue_family;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    /* Anisotropic sampling for the re-projection (xr-viewer.md §12.3), where the GPU has it. */
    VkPhysicalDeviceFeatures have, want;
    memset(&want, 0, sizeof want);
    s->vkGetPhysicalDeviceFeatures(s->vk_physical, &have);
    want.samplerAnisotropy = have.samplerAnisotropy;
    s->vk_anisotropy = have.samplerAnisotropy == VK_TRUE;
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qi;
    dci.pEnabledFeatures = &want;
    XrVulkanDeviceCreateInfoKHR xd = { XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR };
    xd.systemId = s->system;
    xd.pfnGetInstanceProcAddr = p_vkGetInstanceProcAddr;
    xd.vulkanPhysicalDevice = s->vk_physical;
    xd.vulkanCreateInfo = &dci;
    XR_CHECK(s, create_device(s->instance, &xd, &s->vk_device, &vr));
    if (vr != VK_SUCCESS) { set_error(s, "vkCreateDevice: %d", vr); return -1; }
#define LOADD(f) s->f = (PFN_##f)s->vkGetDeviceProcAddr(s->vk_device, #f); if (!s->f) { set_error(s, "Vulkan: %s missing", #f); return -1; }
    VK_DFUNCS(LOADD)
#undef LOADD
    s->vkGetDeviceQueue(s->vk_device, s->vk_queue_family, 0, &s->vk_queue);
    VkCommandPoolCreateInfo pc = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    pc.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pc.queueFamilyIndex = s->vk_queue_family;
    if (s->vkCreateCommandPool(s->vk_device, &pc, NULL, &s->vk_pool) != VK_SUCCESS) { set_error(s, "vkCreateCommandPool failed"); return -1; }
    return 0;
fail:
    return -1;
}

yxr_session *yxr_open(const char *app_name, int want_session, yxr_info *info, char *error, size_t error_size) {
    yxr_info scratch;
    if (!info) info = &scratch;
    memset(info, 0, sizeof *info);
    if (!yxr_available(error, error_size)) return NULL;
    yxr_session *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    pthread_mutex_init(&s->queue_lock, NULL);
#define LOADG(f) PFN_##f f = NULL; p_xrGetInstanceProcAddr(XR_NULL_HANDLE, #f, (PFN_xrVoidFunction *)&f);
    LOADG(xrEnumerateInstanceExtensionProperties)
    LOADG(xrCreateInstance)
#undef LOADG
    if (!xrEnumerateInstanceExtensionProperties || !xrCreateInstance) { set_error(s, "the loader lacks its global functions"); goto fail; }
    uint32_t n = 0;
    XR_CHECK(s, xrEnumerateInstanceExtensionProperties(NULL, 0, &n, NULL));
    XrExtensionProperties *ext = calloc(n ? n : 1, sizeof *ext);
    for (uint32_t i = 0; i < n; i++) ext[i].type = XR_TYPE_EXTENSION_PROPERTIES;
    xrEnumerateInstanceExtensionProperties(NULL, n, &n, ext);
    size_t used = 0;
    for (uint32_t i = 0; i < n; i++) {
        int w = snprintf(info->extensions + used, sizeof info->extensions - used, "%s%s", used ? " " : "", ext[i].extensionName);
        if (w < 0 || (size_t)w >= sizeof info->extensions - used) break;
        used += (size_t)w;
    }
    int vk2 = has_extension(ext, n, XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME);
    info->has_eye_gaze = has_extension(ext, n, XR_EXT_EYE_GAZE_INTERACTION_EXTENSION_NAME);
    info->has_hand_tracking = has_extension(ext, n, XR_EXT_HAND_TRACKING_EXTENSION_NAME);
    info->has_hand_interaction = has_extension(ext, n, "XR_EXT_hand_interaction");
    info->has_fb_eye_social = has_extension(ext, n, "XR_FB_eye_tracking_social");
    info->has_touch_pro = has_extension(ext, n, "XR_FB_touch_controller_pro");
    int convert = has_extension(ext, n, XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME);
    s->depth_ext = has_extension(ext, n, XR_KHR_COMPOSITION_LAYER_DEPTH_EXTENSION_NAME);
    free(ext);
    if (!vk2) { set_error(s, "the runtime offers no XR_KHR_vulkan_enable2"); goto fail; }
    const char *want[10];
    uint32_t nw = 0;
    want[nw++] = XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME;
    if (info->has_eye_gaze) want[nw++] = XR_EXT_EYE_GAZE_INTERACTION_EXTENSION_NAME;
    if (info->has_hand_tracking) want[nw++] = XR_EXT_HAND_TRACKING_EXTENSION_NAME;
    if (info->has_hand_interaction) want[nw++] = "XR_EXT_hand_interaction";
    if (info->has_touch_pro) want[nw++] = "XR_FB_touch_controller_pro";
    if (convert) want[nw++] = XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME;
    if (s->depth_ext) want[nw++] = XR_KHR_COMPOSITION_LAYER_DEPTH_EXTENSION_NAME;
    s->hand_interaction = info->has_hand_interaction;
    s->touch_pro = info->has_touch_pro;
    XrInstanceCreateInfo ci = { XR_TYPE_INSTANCE_CREATE_INFO };
    snprintf(ci.applicationInfo.applicationName, sizeof ci.applicationInfo.applicationName, "%s", app_name ? app_name : "ycode-xr-viewer");
    snprintf(ci.applicationInfo.engineName, sizeof ci.applicationInfo.engineName, "Ycode");
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    ci.enabledExtensionCount = nw;
    ci.enabledExtensionNames = want;
    XR_CHECK(s, xrCreateInstance(&ci, &s->instance));
#define LOADX(f) if (XR_FAILED(p_xrGetInstanceProcAddr(s->instance, #f, (PFN_xrVoidFunction *)&s->f))) { set_error(s, "OpenXR: %s missing", #f); goto fail; }
    XR_FUNCS(LOADX)
#undef LOADX
    if (convert) p_xrGetInstanceProcAddr(s->instance, "xrConvertTimespecTimeToTimeKHR", (PFN_xrVoidFunction *)&s->convert_time);
    XrInstanceProperties ip = { XR_TYPE_INSTANCE_PROPERTIES };
    XR_CHECK(s, s->xrGetInstanceProperties(s->instance, &ip));
    snprintf(info->runtime, sizeof info->runtime, "%s", ip.runtimeName);
    info->runtime_version = (uint32_t)((XR_VERSION_MAJOR(ip.runtimeVersion) << 22) | (XR_VERSION_MINOR(ip.runtimeVersion) << 12) | XR_VERSION_PATCH(ip.runtimeVersion));
    XrSystemGetInfo sg = { XR_TYPE_SYSTEM_GET_INFO };
    sg.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XR_CHECK(s, s->xrGetSystem(s->instance, &sg, &s->system));
    XrSystemEyeGazeInteractionPropertiesEXT eg = { XR_TYPE_SYSTEM_EYE_GAZE_INTERACTION_PROPERTIES_EXT };
    XrSystemHandTrackingPropertiesEXT ht = { XR_TYPE_SYSTEM_HAND_TRACKING_PROPERTIES_EXT };
    XrSystemProperties sp = { XR_TYPE_SYSTEM_PROPERTIES };
    void *chain = NULL;
    if (info->has_eye_gaze) { eg.next = chain; chain = &eg; }
    if (info->has_hand_tracking) { ht.next = chain; chain = &ht; }
    sp.next = chain;
    XR_CHECK(s, s->xrGetSystemProperties(s->instance, s->system, &sp));
    snprintf(info->system_name, sizeof info->system_name, "%s", sp.systemName);
    info->vendor_id = sp.vendorId;
    info->max_layers = sp.graphicsProperties.maxLayerCount;
    info->eye_gaze_supported = info->has_eye_gaze && eg.supportsEyeGazeInteraction;
    info->hand_tracking_supported = info->has_hand_tracking && ht.supportsHandTracking;
    s->eye_gaze = info->eye_gaze_supported;
    s->hand_tracking = info->hand_tracking_supported;
    XrViewConfigurationView vv[2] = { { XR_TYPE_VIEW_CONFIGURATION_VIEW }, { XR_TYPE_VIEW_CONFIGURATION_VIEW } };
    uint32_t nv = 0;
    XR_CHECK(s, s->xrEnumerateViewConfigurationViews(s->instance, s->system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &nv, vv));
    info->view_count = nv;
    for (uint32_t i = 0; i < nv && i < 2; i++) {
        info->recommended_width[i] = vv[i].recommendedImageRectWidth;
        if (i == 0) { s->rec_w = vv[0].recommendedImageRectWidth; s->rec_h = vv[0].recommendedImageRectHeight; }
        info->recommended_height[i] = vv[i].recommendedImageRectHeight;
        info->max_width[i] = vv[i].maxImageRectWidth;
        info->max_height[i] = vv[i].maxImageRectHeight;
    }
    uint32_t nb = 0;
    XrEnvironmentBlendMode bm[8];
    s->xrEnumerateEnvironmentBlendModes(s->instance, s->system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 8, &nb, bm);
    for (uint32_t i = 0; i < nb && i < 8; i++) info->blend_modes |= 1 << bm[i];
    if (!want_session) return s;

    if (vk_setup(s, info)) goto fail;
    if (setup_actions(s)) goto fail;
    XrGraphicsBindingVulkan2KHR gb = { XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR };
    gb.instance = s->vk_instance;
    gb.physicalDevice = s->vk_physical;
    gb.device = s->vk_device;
    gb.queueFamilyIndex = s->vk_queue_family;
    gb.queueIndex = 0;
    XrSessionCreateInfo sc = { XR_TYPE_SESSION_CREATE_INFO };
    sc.next = &gb;
    sc.systemId = s->system;
    XR_CHECK(s, s->xrCreateSession(s->instance, &sc, &s->session));
    uint32_t nf = 0;
    int64_t formats[64];
    s->xrEnumerateSwapchainFormats(s->session, 64, &nf, formats);
    /* The stream's pixels are sRGB-encoded BGRA: an sRGB swapchain shows them
     * as they are. B8G8R8A8 first (no swizzle), then R8G8B8A8. */
    for (uint32_t i = 0; i < nf && !s->format; i++) if (formats[i] == VK_FORMAT_B8G8R8A8_SRGB) { s->format = formats[i]; s->format_bgra = 1; }
    for (uint32_t i = 0; i < nf && !s->format; i++) if (formats[i] == VK_FORMAT_R8G8B8A8_SRGB) s->format = formats[i];
    if (!s->format) { set_error(s, "the runtime offers no 8-bit sRGB swapchain format"); goto fail; }
    info->swapchain_format = s->format;
    info->swapchain_bgra = s->format_bgra;
    XrReferenceSpaceCreateInfo rs = { XR_TYPE_REFERENCE_SPACE_CREATE_INFO };
    rs.poseInReferenceSpace.orientation.w = 1;
    rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    s->space_type = 1;
    if (XR_FAILED(s->xrCreateReferenceSpace(s->session, &rs, &s->base))) {
        rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        s->space_type = 2;
        XR_CHECK(s, s->xrCreateReferenceSpace(s->session, &rs, &s->base));
    }
    info->space = s->space_type;
    rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    XR_CHECK(s, s->xrCreateReferenceSpace(s->session, &rs, &s->view));
    if (session_spaces_and_actions(s)) goto fail;
    return s;
fail:
    if (error && error_size) snprintf(error, error_size, "%s", s->error);
    yxr_close(s);
    return NULL;
}

int yxr_running(yxr_session *s) { return s && s->running; }

int yxr_poll(yxr_session *s, yxr_event *ev) {
    memset(ev, 0, sizeof *ev);
    if (!s || !s->instance) return 0;
    XrEventDataBuffer e = { XR_TYPE_EVENT_DATA_BUFFER };
    if (s->xrPollEvent(s->instance, &e) != XR_SUCCESS) return 0;
    switch (e.type) {
    case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: {
        const XrEventDataSessionStateChanged *c = (const void *)&e;
        s->state = c->state;
        ev->kind = YXR_EVENT_STATE;
        ev->value = c->state;
        if (c->state == XR_SESSION_STATE_READY && s->session) {
            XrSessionBeginInfo bi = { XR_TYPE_SESSION_BEGIN_INFO };
            bi.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            XrResult r = s->xrBeginSession(s->session, &bi);
            if (XR_SUCCEEDED(r)) s->running = 1; else set_error(s, "xrBeginSession: %s", xr_text(s, r));
        } else if (c->state == XR_SESSION_STATE_STOPPING && s->session) {
            s->xrEndSession(s->session);
            s->running = 0;
        } else if (c->state == XR_SESSION_STATE_EXITING) {
            ev->kind = YXR_EVENT_EXIT;
        } else if (c->state == XR_SESSION_STATE_LOSS_PENDING) {
            ev->kind = YXR_EVENT_LOST;
        }
        return 1;
    }
    case XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING: {
        const XrEventDataReferenceSpaceChangePending *c = (const void *)&e;
        ev->kind = YXR_EVENT_RECENTER;
        ev->value = c->referenceSpaceType;
        return 1;
    }
    case XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED:
        ev->kind = YXR_EVENT_PROFILE;
        return 1;
    case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
        ev->kind = YXR_EVENT_LOST;
        return 1;
    default:
        ev->kind = YXR_EVENT_NONE;
        ev->value = e.type;
        return 1;
    }
}

static yxr_pose to_pose(XrPosef p) {
    yxr_pose o = { { p.position.x, p.position.y, p.position.z }, { p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w } };
    return o;
}

static XrPosef from_pose(yxr_pose p) {
    XrPosef o = { { p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w }, { p.position.x, p.position.y, p.position.z } };
    return o;
}

static int locate_flags(yxr_session *s, XrSpace space, XrTime t, yxr_pose *out, void *next, XrSpaceLocationFlags *flags) {
    if (!space) return 0;
    XrSpaceLocation l = { XR_TYPE_SPACE_LOCATION };
    l.next = next;
    if (XR_FAILED(s->xrLocateSpace(space, s->base, t, &l))) return 0;
    const XrSpaceLocationFlags need = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
    if ((l.locationFlags & need) != need) return 0;
    if (flags) *flags = l.locationFlags;
    *out = to_pose(l.pose);
    return 1;
}

static int locate(yxr_session *s, XrSpace space, XrTime t, yxr_pose *out, void *next) {
    return locate_flags(s, space, t, out, next, NULL);
}

static int action_bool(yxr_session *s, XrAction a, XrPath sub) {
    XrActionStateGetInfo gi = { XR_TYPE_ACTION_STATE_GET_INFO };
    gi.action = a;
    gi.subactionPath = sub;
    XrActionStateBoolean b = { XR_TYPE_ACTION_STATE_BOOLEAN };
    return XR_SUCCEEDED(s->xrGetActionStateBoolean(s->session, &gi, &b)) && b.isActive && b.currentState;
}

static float action_float(yxr_session *s, XrAction a, XrPath sub) {
    XrActionStateGetInfo gi = { XR_TYPE_ACTION_STATE_GET_INFO };
    gi.action = a;
    gi.subactionPath = sub;
    XrActionStateFloat f = { XR_TYPE_ACTION_STATE_FLOAT };
    return XR_SUCCEEDED(s->xrGetActionStateFloat(s->session, &gi, &f)) && f.isActive ? f.currentState : 0;
}

int yxr_begin_frame(yxr_session *s, yxr_frame *f) {
    memset(f, 0, sizeof *f);
    if (!s || !s->running) { if (s) set_error(s, "the session is not running"); return -1; }
    s->frame_state = (XrFrameState){ XR_TYPE_FRAME_STATE };
    XR_CHECK(s, s->xrWaitFrame(s->session, NULL, &s->frame_state));
    XR_CHECK(s, s->xrBeginFrame(s->session, NULL));
    s->in_frame = 1;
    XrTime t = s->frame_state.predictedDisplayTime;
    f->display_time = t;
    f->display_period = s->frame_state.predictedDisplayPeriod;
    f->should_render = s->frame_state.shouldRender;
    f->focused = s->state == XR_SESSION_STATE_FOCUSED;
    XrViewLocateInfo vl = { XR_TYPE_VIEW_LOCATE_INFO };
    vl.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    vl.displayTime = t;
    vl.space = s->base;
    XrViewState vs = { XR_TYPE_VIEW_STATE };
    XrView views[2] = { { XR_TYPE_VIEW }, { XR_TYPE_VIEW } };
    uint32_t nv = 0;
    if (XR_SUCCEEDED(s->xrLocateViews(s->session, &vl, &vs, 2, &nv, views)) && nv == 2
        && (vs.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT)) {
        f->views_valid = 1;
        for (int i = 0; i < 2; i++) {
            f->view_pose[i] = to_pose(views[i].pose);
            f->view_fov[i] = (yxr_fov){ views[i].fov.angleLeft, views[i].fov.angleRight, views[i].fov.angleUp, views[i].fov.angleDown };
        }
    }
    f->head_valid = locate(s, s->view, t, &f->head, NULL);
    if (f->focused) {
        XrActiveActionSet aas = { s->actions, XR_NULL_PATH };
        XrActionsSyncInfo si = { XR_TYPE_ACTIONS_SYNC_INFO };
        si.countActiveActionSets = 1;
        si.activeActionSets = &aas;
        s->xrSyncActions(s->session, &si);
        if (s->gaze_space) {
            XrEyeGazeSampleTimeEXT st = { XR_TYPE_EYE_GAZE_SAMPLE_TIME_EXT };
            XrSpaceLocationFlags flags = 0;
            XrTime gaze_at = t;
            if (s->gaze_at_present) { int64_t now = yxr_now(s); if (now > 0) gaze_at = now; }
            f->gaze_valid = locate_flags(s, s->gaze_space, gaze_at, &f->gaze, &st, &flags);
            f->gaze_time = f->gaze_valid ? st.time : 0;
            f->gaze_tracked = (flags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT) != 0;
        }
        for (int h = 0; h < 2; h++) {
            XrPath sub = s->hands[h];
            f->aim_valid[h] = locate(s, s->aim_space[h], t, &f->aim[h], NULL);
            f->grip_valid[h] = locate(s, s->grip_space[h], t, &f->grip[h], NULL);
            f->trigger[h] = action_float(s, s->trigger, sub);
            f->squeeze[h] = action_float(s, s->squeeze, sub);
            XrActionStateGetInfo gi = { XR_TYPE_ACTION_STATE_GET_INFO };
            gi.action = s->stick;
            gi.subactionPath = sub;
            XrActionStateVector2f v = { XR_TYPE_ACTION_STATE_VECTOR2F };
            if (XR_SUCCEEDED(s->xrGetActionStateVector2f(s->session, &gi, &v)) && v.isActive) { f->stick_x[h] = v.currentState.x; f->stick_y[h] = v.currentState.y; }
            f->stick_click[h] = action_bool(s, s->stick_click, sub);
            f->button_lower[h] = action_bool(s, s->lower, sub);
            f->button_upper[h] = action_bool(s, s->upper, sub);
            XrInteractionProfileState ps = { XR_TYPE_INTERACTION_PROFILE_STATE };
            if (XR_SUCCEEDED(s->xrGetCurrentInteractionProfile(s->session, sub, &ps)) && ps.interactionProfile) {
                char name[XR_MAX_PATH_LENGTH] = "";
                uint32_t len = 0;
                s->xrPathToString(s->instance, ps.interactionProfile, sizeof name, &len, name);
                f->hand_profile_active[h] = strstr(name, "hand_interaction") != NULL;
                f->controller_active[h] = !f->hand_profile_active[h] && name[0];
            }
        }
        f->button_menu = action_bool(s, s->menu, XR_NULL_PATH);
    }
    for (int h = 0; h < 2; h++) {
        if (!s->trackers[h] || !s->locate_joints) continue;
        XrHandJointLocationEXT jl[XR_HAND_JOINT_COUNT_EXT];
        XrHandJointLocationsEXT js = { XR_TYPE_HAND_JOINT_LOCATIONS_EXT };
        js.jointCount = XR_HAND_JOINT_COUNT_EXT;
        js.jointLocations = jl;
        XrHandJointsLocateInfoEXT li = { XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT };
        li.baseSpace = s->base;
        li.time = t;
        if (XR_FAILED(s->locate_joints(s->trackers[h], &li, &js)) || !js.isActive) continue;
        f->hand_valid[h] = 1;
        const XrSpaceLocationFlags need = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
        for (int j = 0; j < YXR_JOINTS; j++) {
            f->joint[h][j] = to_pose(jl[j].pose);
            f->joint_radius[h][j] = jl[j].radius;
            if ((jl[j].locationFlags & need) == need) f->joint_valid[h] |= 1u << j;
        }
    }
    return 0;
fail:
    return -1;
}

static uint32_t memory_type(yxr_session *s, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < s->vk_memory.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (s->vk_memory.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static void destroy_chain(yxr_session *s, eye_chain *c) {
    if (c->fence_pending && c->fence) { s->vkWaitForFences(s->vk_device, 1, &c->fence, VK_TRUE, UINT64_MAX); c->fence_pending = 0; }
    if (c->handle) s->xrDestroySwapchain(c->handle);
    if (c->staging_map) s->vkUnmapMemory(s->vk_device, c->staging_memory);
    if (c->staging) s->vkDestroyBuffer(s->vk_device, c->staging, NULL);
    if (c->staging_memory) s->vkFreeMemory(s->vk_device, c->staging_memory, NULL);
    if (c->fence) s->vkDestroyFence(s->vk_device, c->fence, NULL);
    memset(c, 0, sizeof *c);
}

static int make_chain_format(yxr_session *s, eye_chain *c, int width, int height, int64_t format, int depth);

static int make_chain(yxr_session *s, eye_chain *c, int width, int height) {
    return make_chain_format(s, c, width, height, s->format, 0);
}

static int make_chain_format(yxr_session *s, eye_chain *c, int width, int height, int64_t format, int depth) {
    destroy_chain(s, c);
    XrSwapchainCreateInfo sc = { XR_TYPE_SWAPCHAIN_CREATE_INFO };
    sc.usageFlags = depth ? (XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT)
                          : (XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT);
    sc.format = format;
    sc.sampleCount = 1;
    sc.width = (uint32_t)width;
    sc.height = (uint32_t)height;
    sc.faceCount = 1;
    sc.arraySize = 1;
    sc.mipCount = 1;
    XR_CHECK(s, s->xrCreateSwapchain(s->session, &sc, &c->handle));
    XrSwapchainImageVulkan2KHR imgs[8];
    for (int i = 0; i < 8; i++) imgs[i] = (XrSwapchainImageVulkan2KHR){ XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR };
    uint32_t n = 0;
    XR_CHECK(s, s->xrEnumerateSwapchainImages(c->handle, 8, &n, (XrSwapchainImageBaseHeader *)imgs));
    c->count = n;
    for (uint32_t i = 0; i < n; i++) c->images[i] = imgs[i].image;
    c->width = (uint32_t)width;
    c->height = (uint32_t)height;
    c->staging_size = (size_t)width * (size_t)height * 4;
    VkBufferCreateInfo bi = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bi.size = c->staging_size;
    bi.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    if (s->vkCreateBuffer(s->vk_device, &bi, NULL, &c->staging) != VK_SUCCESS) { set_error(s, "vkCreateBuffer failed"); return -1; }
    VkMemoryRequirements mr;
    s->vkGetBufferMemoryRequirements(s->vk_device, c->staging, &mr);
    VkMemoryAllocateInfo ma = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    ma.allocationSize = mr.size;
    ma.memoryTypeIndex = memory_type(s, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (ma.memoryTypeIndex == UINT32_MAX || s->vkAllocateMemory(s->vk_device, &ma, NULL, &c->staging_memory) != VK_SUCCESS) { set_error(s, "no host-visible memory"); return -1; }
    s->vkBindBufferMemory(s->vk_device, c->staging, c->staging_memory, 0);
    if (s->vkMapMemory(s->vk_device, c->staging_memory, 0, VK_WHOLE_SIZE, 0, &c->staging_map) != VK_SUCCESS) { set_error(s, "vkMapMemory failed"); return -1; }
    VkCommandBufferAllocateInfo ca = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    ca.commandPool = s->vk_pool;
    ca.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ca.commandBufferCount = 1;
    if (s->vkAllocateCommandBuffers(s->vk_device, &ca, &c->cmd) != VK_SUCCESS) { set_error(s, "vkAllocateCommandBuffers failed"); return -1; }
    VkFenceCreateInfo fi = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (s->vkCreateFence(s->vk_device, &fi, NULL, &c->fence) != VK_SUCCESS) { set_error(s, "vkCreateFence failed"); return -1; }
    return 0;
fail:
    return -1;
}

/* The staging buffer of eye `eye`, sized for width x height (the chain
 * made or remade), its earlier copy finished; NULL on failure. */
static eye_chain *staging_for(yxr_session *s, int eye, int width, int height) {
    if (!s || !s->in_frame || eye < 0 || eye > 13 || (eye >= 6 && eye <= 9) || width <= 0 || height <= 0) return NULL;   /* uploads: 0–5, 10–13 */
    eye_chain *c = &s->eye[eye];
    if (!c->handle || c->width != (uint32_t)width || c->height != (uint32_t)height)
        if (make_chain(s, c, width, height)) return NULL;
    if (c->fence_pending) {
        s->vkWaitForFences(s->vk_device, 1, &c->fence, VK_TRUE, UINT64_MAX);
        s->vkResetFences(s->vk_device, 1, &c->fence);
        c->fence_pending = 0;
    }
    return c;
}

static int copy_staging_to_swapchain(yxr_session *s, eye_chain *c, int width, int height);

int yxr_upload(yxr_session *s, int eye, const void *bgra, int width, int height, int stride) {
    eye_chain *c = staging_for(s, eye, width, height);
    if (!c) return -1;
    /* Into the staging buffer (tightly packed), swizzled when the swapchain is RGBA. */
    const uint8_t *src = bgra;
    uint8_t *dst = c->staging_map;
    size_t row = (size_t)width * 4;
    for (int y = 0; y < height; y++) {
        const uint8_t *sr = src + (size_t)y * (size_t)stride;
        uint8_t *dr = dst + (size_t)y * row;
        if (s->format_bgra) memcpy(dr, sr, row);
        else for (int x = 0; x < width; x++) { dr[4 * x] = sr[4 * x + 2]; dr[4 * x + 1] = sr[4 * x + 1]; dr[4 * x + 2] = sr[4 * x]; dr[4 * x + 3] = 255; }
    }
    return copy_staging_to_swapchain(s, c, width, height);
}

int yxr_upload_nv12(yxr_session *s, int eye, const uint8_t *y, const uint8_t *uv, int pitch, int width, int height) {
    eye_chain *c = staging_for(s, eye, width, height);
    if (!c || !y || !uv) return -1;
    yxr_convert_nv12(y, uv, pitch, width, height, c->staging_map, s->format_bgra);
    return copy_staging_to_swapchain(s, c, width, height);
}

int yxr_upload_yuv444(yxr_session *s, int eye, const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height) {
    eye_chain *c = staging_for(s, eye, width, height);
    if (!c || !y || !u || !v) return -1;
    yxr_convert_yuv444(y, u, v, pitch, width, height, c->staging_map, s->format_bgra);
    return copy_staging_to_swapchain(s, c, width, height);
}

void yxr_set_gaze_at_present(yxr_session *s, int on) { if (s) s->gaze_at_present = on; }

static int copy_staging_to_swapchain(yxr_session *s, eye_chain *c, int width, int height) {
    uint32_t index = 0;
    XrSwapchainImageAcquireInfo ai = { XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
    XR_CHECK(s, s->xrAcquireSwapchainImage(c->handle, &ai, &index));
    XrSwapchainImageWaitInfo wi = { XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
    wi.timeout = 100000000;   /* 100 ms */
    XR_CHECK(s, s->xrWaitSwapchainImage(c->handle, &wi));
    VkImage image = c->images[index];
    s->vkResetCommandBuffer(c->cmd, 0);
    VkCommandBufferBeginInfo cb = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    s->vkBeginCommandBuffer(c->cmd, &cb);
    VkImageMemoryBarrier b = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    b.srcAccessMask = 0;
    b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    b.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    b.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    s->vkCmdPipelineBarrier(c->cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    VkBufferImageCopy copy = { 0 };
    copy.imageSubresource = (VkImageSubresourceLayers){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    copy.imageExtent = (VkExtent3D){ (uint32_t)width, (uint32_t)height, 1 };
    s->vkCmdCopyBufferToImage(c->cmd, c->staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    /* OpenXR expects a colour swapchain image back in COLOR_ATTACHMENT_OPTIMAL. */
    b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    b.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_SHADER_READ_BIT;
    b.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    b.newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    s->vkCmdPipelineBarrier(c->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &b);
    s->vkEndCommandBuffer(c->cmd);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &c->cmd;
    pthread_mutex_lock(&s->queue_lock);
    VkResult qr = s->vkQueueSubmit(s->vk_queue, 1, &si, c->fence);
    pthread_mutex_unlock(&s->queue_lock);
    if (qr != VK_SUCCESS) { set_error(s, "vkQueueSubmit failed"); return -1; }
    c->fence_pending = 1;
    XrSwapchainImageReleaseInfo ri = { XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
    XR_CHECK(s, s->xrReleaseSwapchainImage(c->handle, &ri));
    c->released_once = 1;
    return 0;
fail:
    return -1;
}

int yxr_end_frame(yxr_session *s, const yxr_submit *sub) {
    if (!s || !s->in_frame) return -1;
    s->in_frame = 0;
    XrCompositionLayerProjectionView pv[2];
    XrCompositionLayerProjection layer = { XR_TYPE_COMPOSITION_LAYER_PROJECTION };
    const XrCompositionLayerBaseHeader *layers[2 + YXR_MAX_SPRITES];
    XrCompositionLayerProjectionView iv[2];
    XrCompositionLayerProjection inset = { XR_TYPE_COMPOSITION_LAYER_PROJECTION };
    XrCompositionLayerQuad quads[YXR_MAX_SPRITES];
    XrCompositionLayerDepthInfoKHR dinfo[2];
    uint32_t count = 0;
    if (sub && sub->submit && s->frame_state.shouldRender) {
        int ok = 1;
        for (int i = 0; i < 2; i++) {
            int img = sub->render[i] ? 6 + i : sub->image[i];
            if (!(img == 0 || img == 1 || img == 6 || img == 7 || img == 10) || !s->eye[img].handle || !s->eye[img].released_once) { ok = 0; break; }
            pv[i] = (XrCompositionLayerProjectionView){ XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW };
            pv[i].pose = from_pose(sub->pose[i]);
            pv[i].fov = (XrFovf){ sub->fov[i].angle_left, sub->fov[i].angle_right, sub->fov[i].angle_up, sub->fov[i].angle_down };
            pv[i].subImage.swapchain = s->eye[img].handle;
            pv[i].subImage.imageRect.offset = (XrOffset2Di){ 0, 0 };
            pv[i].subImage.imageRect.extent = (XrExtent2Di){ (int32_t)s->eye[img].width, (int32_t)s->eye[img].height };
            pv[i].subImage.imageArrayIndex = 0;
            pv[i].next = NULL;
            /* Hook c: the eye's depth for the runtime's reprojection. */
            if (sub->depth_valid[i] && s->depth_ext && s->eye[8 + i].handle && s->eye[8 + i].released_once) {
                dinfo[i] = (XrCompositionLayerDepthInfoKHR){ XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR };
                dinfo[i].subImage.swapchain = s->eye[8 + i].handle;
                dinfo[i].subImage.imageRect.extent = (XrExtent2Di){ (int32_t)s->eye[8 + i].width, (int32_t)s->eye[8 + i].height };
                dinfo[i].minDepth = 0;
                dinfo[i].maxDepth = 1;
                dinfo[i].nearZ = sub->depth_near > 0 ? sub->depth_near : 0.1f;
                dinfo[i].farZ = sub->depth_far > 0 ? sub->depth_far : 1e6f;
                pv[i].next = &dinfo[i];
            }
        }
        if (ok) {
            layer.space = s->base;
            layer.viewCount = 2;
            layer.views = pv;
            layers[0] = (const XrCompositionLayerBaseHeader *)&layer;
            count = 1;
        }
    }
    XrFrameEndInfo fe = { XR_TYPE_FRAME_END_INFO };
    fe.displayTime = s->frame_state.predictedDisplayTime;
    fe.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    /* The foveal insets over the picture, same pose, their own sub-frustum. */
    if (count == 1 && sub->inset && !sub->render[0] && !sub->render[1]) {
        int ok = 1;
        for (int i = 0; i < 2; i++) {
            int img = sub->inset_image[i];
            if (!(img == 4 || img == 5 || img == 11) || !s->eye[img].handle || !s->eye[img].released_once) { ok = 0; break; }
            iv[i] = pv[i];
            iv[i].next = NULL;
            iv[i].fov = (XrFovf){ sub->inset_fov[i].angle_left, sub->inset_fov[i].angle_right, sub->inset_fov[i].angle_up, sub->inset_fov[i].angle_down };
            iv[i].subImage.swapchain = s->eye[img].handle;
            iv[i].subImage.imageRect.offset = (XrOffset2Di){ 0, 0 };
            iv[i].subImage.imageRect.extent = (XrExtent2Di){ (int32_t)s->eye[img].width, (int32_t)s->eye[img].height };
        }
        if (ok) {
            inset.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT | XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
            inset.space = s->base;
            inset.viewCount = 2;
            inset.views = iv;
            layers[count++] = (const XrCompositionLayerBaseHeader *)&inset;
        }
    }
    /* The sprites over it (hands), alpha-blended, both eyes. */
    if (sub && sub->sprites && s->frame_state.shouldRender) {
        int n = sub->sprite_count < YXR_MAX_SPRITES ? sub->sprite_count : YXR_MAX_SPRITES;
        for (int i = 0; i < n; i++) {
            const yxr_sprite *sp = &sub->sprites[i];
            if (!(sp->image == 2 || sp->image == 3 || sp->image == 12 || sp->image == 13) || !s->eye[sp->image].handle || !s->eye[sp->image].released_once) continue;
            XrCompositionLayerQuad *q = &quads[i];
            *q = (XrCompositionLayerQuad){ XR_TYPE_COMPOSITION_LAYER_QUAD };
            q->layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT | XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
            q->space = s->base;
            q->eyeVisibility = XR_EYE_VISIBILITY_BOTH;
            q->subImage.swapchain = s->eye[sp->image].handle;
            q->subImage.imageRect.extent = (XrExtent2Di){ (int32_t)s->eye[sp->image].width, (int32_t)s->eye[sp->image].height };
            q->pose = from_pose(sp->pose);
            q->size = (XrExtent2Df){ sp->size, sp->size };
            layers[count++] = (const XrCompositionLayerBaseHeader *)q;
        }
    }
    fe.layerCount = count;
    fe.layers = layers;
    XR_CHECK(s, s->xrEndFrame(s->session, &fe));
    return 0;
fail:
    return -1;
}

int yxr_vulkan(yxr_session *s, yxr_vulkan_handles *o) {
    if (!s || !s->vk_device || !o) return -1;
    o->instance = (void *)s->vk_instance;
    o->physical_device = (void *)s->vk_physical;
    o->device = (void *)s->vk_device;
    o->queue_family = s->vk_queue_family;
    o->queue = (void *)s->vk_queue;
    o->get_instance_proc_addr = (void *)p_vkGetInstanceProcAddr;
    o->color_format = s->format;
    o->recommended_width = s->rec_w;
    o->recommended_height = s->rec_h;
    o->anisotropy = s->vk_anisotropy;
    return 0;
}

void yxr_queue_lock(yxr_session *s) { if (s) pthread_mutex_lock(&s->queue_lock); }
void yxr_queue_unlock(yxr_session *s) { if (s) pthread_mutex_unlock(&s->queue_lock); }

/* Acquire the next image of slot `slot` (made at the recommended size on first use). */
static int acquire_slot(yxr_session *s, int slot, int64_t format, int depth, uint64_t *image, int *w, int *h, int64_t *f) {
    if (!s || !s->in_frame || !s->rec_w) return -1;
    eye_chain *c = &s->eye[slot];
    if (!c->handle && make_chain_format(s, c, (int)s->rec_w, (int)s->rec_h, format, depth)) return -1;
    uint32_t index = 0;
    XrSwapchainImageAcquireInfo ai = { XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO };
    XR_CHECK(s, s->xrAcquireSwapchainImage(c->handle, &ai, &index));
    XrSwapchainImageWaitInfo wi = { XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO };
    wi.timeout = 100000000;
    XR_CHECK(s, s->xrWaitSwapchainImage(c->handle, &wi));
    if (image) *image = (uint64_t)(uintptr_t)c->images[index];
    if (w) *w = (int)c->width;
    if (h) *h = (int)c->height;
    if (f) *f = format;
    return 0;
fail:
    return -1;
}

static int release_slot(yxr_session *s, int slot) {
    if (!s || !s->eye[slot].handle) return -1;
    XrSwapchainImageReleaseInfo ri = { XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO };
    XR_CHECK(s, s->xrReleaseSwapchainImage(s->eye[slot].handle, &ri));
    s->eye[slot].released_once = 1;
    return 0;
fail:
    return -1;
}

int yxr_acquire_render(yxr_session *s, int eye, uint64_t *image, int *width, int *height, int64_t *format) {
    if (!s || eye < 0 || eye > 1) return -1;
    return acquire_slot(s, 6 + eye, s->format, 0, image, width, height, format);
}
int yxr_release_render(yxr_session *s, int eye) { return s && eye >= 0 && eye <= 1 ? release_slot(s, 6 + eye) : -1; }
int yxr_has_depth_layers(yxr_session *s) { return s && s->depth_ext ? 1 : -1; }
int yxr_acquire_depth(yxr_session *s, int eye, uint64_t *image, int *width, int *height, int64_t *format) {
    if (!s || !s->depth_ext || eye < 0 || eye > 1) return -1;
    return acquire_slot(s, 8 + eye, VK_FORMAT_D32_SFLOAT, 1, image, width, height, format);
}
int yxr_release_depth(yxr_session *s, int eye) { return s && eye >= 0 && eye <= 1 ? release_slot(s, 8 + eye) : -1; }

int64_t yxr_now(yxr_session *s) {
    if (!s || !s->convert_time) return 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    XrTime t = 0;
    return XR_SUCCEEDED(s->convert_time(s->instance, &ts, &t)) ? t : 0;
}

void yxr_request_exit(yxr_session *s) {
    if (s && s->session && s->running && !s->exit_requested) { s->xrRequestExitSession(s->session); s->exit_requested = 1; }
}

void yxr_close(yxr_session *s) {
    if (!s) return;
    if (s->vk_device && s->vkDeviceWaitIdle) s->vkDeviceWaitIdle(s->vk_device);
    for (int i = 0; i < 14; i++) if (s->eye[i].handle || s->eye[i].staging) destroy_chain(s, &s->eye[i]);
    pthread_mutex_destroy(&s->queue_lock);
    for (int h = 0; h < 2; h++) if (s->trackers[h] && s->destroy_tracker) s->destroy_tracker(s->trackers[h]);
    if (s->session) {
        if (s->running) s->xrEndSession(s->session);
        s->xrDestroySession(s->session);
    }
    if (s->vk_pool) s->vkDestroyCommandPool(s->vk_device, s->vk_pool, NULL);
    if (s->vk_device && s->vkDestroyDevice) s->vkDestroyDevice(s->vk_device, NULL);
    if (s->vk_instance && s->vkDestroyInstance) s->vkDestroyInstance(s->vk_instance, NULL);
    if (s->instance && s->xrDestroyInstance) s->xrDestroyInstance(s->instance);
    free(s);
}

#else  /* not Linux: OpenXR is not offered */
int yxr_upload_yuv444(yxr_session *s, int eye, const uint8_t *y, const uint8_t *u, const uint8_t *v, int p, int w, int h) { (void)s; (void)eye; (void)y; (void)u; (void)v; (void)p; (void)w; (void)h; return -1; }
void yxr_set_gaze_at_present(yxr_session *s, int on) { (void)s; (void)on; }

static const char unavailable[] = "OpenXR viewing is offered on Linux only";
int yxr_available(char *error, size_t error_size) { if (error && error_size) snprintf(error, error_size, "%s", unavailable); return 0; }
yxr_session *yxr_open(const char *app_name, int session, yxr_info *info, char *error, size_t error_size) {
    (void)app_name; (void)session;
    if (info) memset(info, 0, sizeof *info);
    yxr_available(error, error_size);
    return NULL;
}
int yxr_poll(yxr_session *s, yxr_event *e) { (void)s; if (e) memset(e, 0, sizeof *e); return 0; }
int yxr_running(yxr_session *s) { (void)s; return 0; }
int yxr_begin_frame(yxr_session *s, yxr_frame *f) { (void)s; (void)f; return -1; }
int yxr_upload(yxr_session *s, int eye, const void *b, int w, int h, int st) { (void)s; (void)eye; (void)b; (void)w; (void)h; (void)st; return -1; }
int yxr_upload_nv12(yxr_session *s, int eye, const uint8_t *y, const uint8_t *uv, int p, int w, int h) { (void)s; (void)eye; (void)y; (void)uv; (void)p; (void)w; (void)h; return -1; }
int yxr_end_frame(yxr_session *s, const yxr_submit *sub) { (void)s; (void)sub; return -1; }
void yxr_request_exit(yxr_session *s) { (void)s; }
int64_t yxr_now(yxr_session *s) { (void)s; return 0; }
int yxr_vulkan(yxr_session *s, yxr_vulkan_handles *o) { (void)s; (void)o; return -1; }
int yxr_acquire_render(yxr_session *s, int eye, uint64_t *i, int *w, int *h, int64_t *f) { (void)s; (void)eye; (void)i; (void)w; (void)h; (void)f; return -1; }
int yxr_release_render(yxr_session *s, int eye) { (void)s; (void)eye; return -1; }
int yxr_has_depth_layers(yxr_session *s) { (void)s; return -1; }
int yxr_acquire_depth(yxr_session *s, int eye, uint64_t *i, int *w, int *h, int64_t *f) { (void)s; (void)eye; (void)i; (void)w; (void)h; (void)f; return -1; }
int yxr_release_depth(yxr_session *s, int eye) { (void)s; (void)eye; return -1; }
void yxr_queue_lock(yxr_session *s) { (void)s; }
void yxr_queue_unlock(yxr_session *s) { (void)s; }
void yxr_close(yxr_session *s) { (void)s; }
const char *yxr_last_error(yxr_session *s) { (void)s; return unavailable; }

#endif

/* YUV → BGRA or RGBA on several threads, on any platform (the display path's
 * upload, and offscreen replays and tests). BT.709 limited range, as the
 * encoder's RGB → YUV conversion (display-stream.md §14). */
#include <pthread.h>

typedef struct {
    const uint8_t *y, *u, *v;           /* v NULL: u is NV12's interleaved chroma */
    int pitch, width, row0, row1, bgra;
    uint8_t *dst;
} yuv_job;

static inline uint8_t yuv_clamp(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

static void *yuv_rows(void *arg) {
    const yuv_job *j = arg;
    const int blue = j->bgra ? 0 : 2, red = j->bgra ? 2 : 0;
    for (int r = j->row0; r < j->row1; r++) {
        const uint8_t *yr = j->y + (size_t)r * j->pitch;
        uint8_t *o = j->dst + (size_t)r * j->width * 4;
        if (j->v) {
            const uint8_t *ur = j->u + (size_t)r * j->pitch, *vr = j->v + (size_t)r * j->pitch;
            for (int i = 0; i < j->width; i++) {
                int c = 298 * ((int)yr[i] - 16), d = (int)ur[i] - 128, e = (int)vr[i] - 128;
                o[i * 4 + blue] = yuv_clamp((c + 541 * d + 128) >> 8);
                o[i * 4 + 1] = yuv_clamp((c - 55 * d - 136 * e + 128) >> 8);
                o[i * 4 + red] = yuv_clamp((c + 459 * e + 128) >> 8);
                o[i * 4 + 3] = 255;
            }
        } else {
            const uint8_t *uvr = j->u + (size_t)(r / 2) * j->pitch;
            for (int i = 0; i < j->width; i++) {
                int c = 298 * ((int)yr[i] - 16), d = (int)uvr[i & ~1] - 128, e = (int)uvr[(i & ~1) + 1] - 128;
                o[i * 4 + blue] = yuv_clamp((c + 541 * d + 128) >> 8);
                o[i * 4 + 1] = yuv_clamp((c - 55 * d - 136 * e + 128) >> 8);
                o[i * 4 + red] = yuv_clamp((c + 459 * e + 128) >> 8);
                o[i * 4 + 3] = 255;
            }
        }
    }
    return NULL;
}

static void yuv_convert(const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height, uint8_t *dst, int bgra) {
    enum { JOBS = 8 };
    yuv_job jobs[JOBS];
    pthread_t threads[JOBS];
    int started[JOBS] = { 0 };
    int band = ((height + JOBS - 1) / JOBS + 1) & ~1;
    for (int k = 0; k < JOBS; k++) {
        jobs[k] = (yuv_job){ y, u, v, pitch, width, k * band, (k + 1) * band > height ? height : (k + 1) * band, bgra, dst };
        if (jobs[k].row0 >= jobs[k].row1) continue;
        started[k] = k > 0 && pthread_create(&threads[k], NULL, yuv_rows, &jobs[k]) == 0;
        if (!started[k] && k > 0) yuv_rows(&jobs[k]);
    }
    if (jobs[0].row0 < jobs[0].row1) yuv_rows(&jobs[0]);
    for (int k = 1; k < JOBS; k++) if (started[k]) pthread_join(threads[k], NULL);
}

void yxr_convert_yuv444(const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height, uint8_t *dst, int bgra) {
    yuv_convert(y, u, v, pitch, width, height, dst, bgra);
}

void yxr_convert_nv12(const uint8_t *y, const uint8_t *uv, int pitch, int width, int height, uint8_t *dst, int bgra) {
    yuv_convert(y, uv, NULL, pitch, width, height, dst, bgra);
}
