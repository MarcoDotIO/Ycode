/*
 * COVSDL: run-time loading of SDL3 and two helpers that need C (see
 * include/ov_sdl.h). Original code; SDL is used only through its public API.
 */
#include "ov_sdl.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static OVSDLAPI ov_api;
static int ov_loaded = 0;
static char ov_path[1024];

static void *ov_try_open(const char *path) {
    if (path == NULL || path[0] == '\0') return NULL;
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (h != NULL) snprintf(ov_path, sizeof ov_path, "%s", path);
    return h;
}

static void *ov_open_library(const char *explicit_path) {
    void *h = ov_try_open(explicit_path);
    if (h) return h;
    h = ov_try_open(getenv("OV_SDL3_LIBRARY"));
    if (h) return h;
#if defined(__APPLE__)
    static const char *names[] = { "libSDL3.0.dylib", "libSDL3.dylib",
                                   "/opt/homebrew/lib/libSDL3.0.dylib", "/usr/local/lib/libSDL3.0.dylib", NULL };
#else
    static const char *names[] = { "libSDL3.so.0", "libSDL3.so", NULL };
#endif
    for (int i = 0; names[i]; i++) {
        h = ov_try_open(names[i]);
        if (h) return h;
    }
    const char *home = getenv("HOME");
    if (home) {
        char p[1024];
#if defined(__APPLE__)
        snprintf(p, sizeof p, "%s/.local/lib/libSDL3.0.dylib", home);
#else
        snprintf(p, sizeof p, "%s/.local/lib/libSDL3.so.0", home);
#endif
        h = ov_try_open(p);
    }
    return h;
}

#define OV_RESOLVE(name)                                                        \
    do {                                                                        \
        *(void **)(&ov_api.name) = dlsym(handle, "SDL_" #name);                 \
        if (ov_api.name == NULL) {                                              \
            snprintf(error, error_len, "SDL3 library lacks SDL_%s", #name);     \
            return NULL;                                                        \
        }                                                                       \
    } while (0)

const OVSDLAPI *ov_sdl_load(const char *path, char *error, size_t error_len) {
    if (ov_loaded) return &ov_api;
    void *handle = ov_open_library(path);
    if (handle == NULL) {
        snprintf(error, error_len, "libSDL3 not found (set OV_SDL3_LIBRARY or LD_LIBRARY_PATH): %s", dlerror());
        return NULL;
    }
    OV_RESOLVE(Init);
    OV_RESOLVE(Quit);
    OV_RESOLVE(GetError);
    OV_RESOLVE(SetHint);
    OV_RESOLVE(GetVersion);
    OV_RESOLVE(GetCurrentVideoDriver);
    OV_RESOLVE(CreateWindow);
    OV_RESOLVE(CreatePopupWindow);
    OV_RESOLVE(DestroyWindow);
    OV_RESOLVE(GetWindowID);
    OV_RESOLVE(GetWindowSize);
    OV_RESOLVE(SetWindowSize);
    OV_RESOLVE(GetWindowSizeInPixels);
    OV_RESOLVE(GetWindowDisplayScale);
    OV_RESOLVE(SetWindowTitle);
    OV_RESOLVE(ShowWindow);
    OV_RESOLVE(GetWindowProperties);
    OV_RESOLVE(GetPointerProperty);
    OV_RESOLVE(GetNumberProperty);
    OV_RESOLVE(GetDisplayForWindow);
    OV_RESOLVE(GetCurrentDisplayMode);
    OV_RESOLVE(GetDisplayUsableBounds);
    OV_RESOLVE(SetWindowPosition);
    OV_RESOLVE(RaiseWindow);
    OV_RESOLVE(GetWindowSurface);
    OV_RESOLVE(UpdateWindowSurface);
    OV_RESOLVE(CreateSurfaceFrom);
    OV_RESOLVE(DestroySurface);
    OV_RESOLVE(ConvertSurface);
    OV_RESOLVE(LockSurface);
    OV_RESOLVE(UnlockSurface);
    OV_RESOLVE(BlitSurface);
    OV_RESOLVE(PollEvent);
    OV_RESOLVE(WaitEventTimeout);
    OV_RESOLVE(PushEvent);
    OV_RESOLVE(PumpEvents);
    OV_RESOLVE(HasEvents);
    OV_RESOLVE(RegisterEvents);
    OV_RESOLVE(StartTextInput);
    OV_RESOLVE(StopTextInput);
    OV_RESOLVE(SetTextInputArea);
    OV_RESOLVE(SetClipboardText);
    OV_RESOLVE(GetClipboardText);
    OV_RESOLVE(HasClipboardText);
    OV_RESOLVE(free);
    OV_RESOLVE(OpenURL);
    OV_RESOLVE(GetTicksNS);
    OV_RESOLVE(Vulkan_GetInstanceExtensions);
    OV_RESOLVE(Vulkan_CreateSurface);
    OV_RESOLVE(Vulkan_DestroySurface);
    OV_RESOLVE(Vulkan_GetVkGetInstanceProcAddr);
    OV_RESOLVE(Vulkan_LoadLibrary);
    OV_RESOLVE(GetSystemTheme);
    OV_RESOLVE(MinimizeWindow);
    OV_RESOLVE(GetWindowPosition);
    ov_loaded = 1;
    return &ov_api;
}

const char *ov_sdl_loaded_path(void) { return ov_path; }

int ov_sdl_display_fd(const OVSDLAPI *api, SDL_Window *window) {
    SDL_PropertiesID props = api->GetWindowProperties(window);
    if (props == 0) return -1;
    void *x11 = api->GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    if (x11 != NULL) {
        /* SDL opened libX11 itself; RTLD_NOLOAD finds that copy without loading another. */
        void *lib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_NOLOAD);
        int (*connection_number)(void *) = lib ? (int (*)(void *))dlsym(lib, "XConnectionNumber") : NULL;
        if (connection_number) return connection_number(x11);
    }
    void *wl = api->GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    if (wl != NULL) {
        void *lib = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_NOLOAD);
        int (*get_fd)(void *) = lib ? (int (*)(void *))dlsym(lib, "wl_display_get_fd") : NULL;
        if (get_fd) return get_fd(wl);
    }
    return -1;
}

int ov_sdl_x11_focus(const OVSDLAPI *api, SDL_Window *window) {
    SDL_PropertiesID props = api->GetWindowProperties(window);
    if (props == 0) return 0;
    void *x11 = api->GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, NULL);
    if (x11 == NULL) return 0;
    long long xid = (long long)api->GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (xid == 0) return 0;
    void *lib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_NOLOAD);
    if (lib == NULL) return 0;
    /* Xlib: XSetInputFocus(display, window, RevertToParent = 2, CurrentTime = 0), XFlush. */
    int (*set_focus)(void *, unsigned long, int, unsigned long) =
        (int (*)(void *, unsigned long, int, unsigned long))dlsym(lib, "XSetInputFocus");
    int (*flush)(void *) = (int (*)(void *))dlsym(lib, "XFlush");
    if (set_focus == NULL || flush == NULL) return 0;
    set_focus(x11, (unsigned long)xid, 2, 0);
    flush(x11);
    return 1;
}

/* ---- Vulkan surface probe -------------------------------------------------
 * Minimal declarations of the Vulkan 1.0 structures and entry points used
 * below, written from the Vulkan specification (Khronos). Handles are opaque
 * pointers (dispatchable) or the SDL typedef (VkSurfaceKHR).
 */
typedef struct ov_VkApplicationInfo {
    int32_t sType; /* VK_STRUCTURE_TYPE_APPLICATION_INFO = 0 */
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} ov_VkApplicationInfo;

typedef struct ov_VkInstanceCreateInfo {
    int32_t sType; /* VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1 */
    const void *pNext;
    uint32_t flags;
    const ov_VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} ov_VkInstanceCreateInfo;

typedef struct ov_VkQueueFamilyProperties {
    uint32_t queueFlags, queueCount, timestampValidBits;
    uint32_t minImageTransferGranularity[3];
} ov_VkQueueFamilyProperties;

typedef struct ov_VkSurfaceCapabilitiesKHR {
    uint32_t minImageCount, maxImageCount;
    uint32_t currentExtent[2], minImageExtent[2], maxImageExtent[2];
    uint32_t maxImageArrayLayers, supportedTransforms, currentTransform;
    uint32_t supportedCompositeAlpha, supportedUsageFlags;
} ov_VkSurfaceCapabilitiesKHR;

typedef void *ov_VkInstance;
typedef void *ov_VkPhysicalDevice;
typedef void (*ov_PFN_void)(void);
typedef ov_PFN_void (*ov_PFN_GetInstanceProcAddr)(ov_VkInstance, const char *);
typedef int32_t (*ov_PFN_CreateInstance)(const ov_VkInstanceCreateInfo *, const void *, ov_VkInstance *);
typedef void (*ov_PFN_DestroyInstance)(ov_VkInstance, const void *);
typedef int32_t (*ov_PFN_EnumeratePhysicalDevices)(ov_VkInstance, uint32_t *, ov_VkPhysicalDevice *);
typedef void (*ov_PFN_GetPhysicalDeviceProperties)(ov_VkPhysicalDevice, void *);
typedef void (*ov_PFN_GetQueueFamilyProperties)(ov_VkPhysicalDevice, uint32_t *, ov_VkQueueFamilyProperties *);
typedef int32_t (*ov_PFN_GetSurfaceSupport)(ov_VkPhysicalDevice, uint32_t, VkSurfaceKHR, uint32_t *);
typedef int32_t (*ov_PFN_GetSurfaceCapabilities)(ov_VkPhysicalDevice, VkSurfaceKHR, ov_VkSurfaceCapabilitiesKHR *);

int ov_vk_probe_surface(const OVSDLAPI *api, SDL_Window *window, char *report, size_t report_len) {
    report[0] = '\0';
    ov_PFN_GetInstanceProcAddr gipa = (ov_PFN_GetInstanceProcAddr)api->Vulkan_GetVkGetInstanceProcAddr();
    if (gipa == NULL) {
        snprintf(report, report_len, "no Vulkan loader: %s", api->GetError());
        return -1;
    }
    Uint32 ext_count = 0;
    const char *const *exts = api->Vulkan_GetInstanceExtensions(&ext_count);
    if (exts == NULL) {
        snprintf(report, report_len, "no instance extensions: %s", api->GetError());
        return -2;
    }
    ov_PFN_CreateInstance create_instance = (ov_PFN_CreateInstance)gipa(NULL, "vkCreateInstance");
    if (create_instance == NULL) {
        snprintf(report, report_len, "vkCreateInstance missing");
        return -3;
    }
    ov_VkApplicationInfo app = { 0, NULL, "OpenViews", 1, "OpenViews", 1, (1u << 22) /* 1.0 */ };
    ov_VkInstanceCreateInfo info = { 1, NULL, 0, &app, 0, NULL, ext_count, exts };
    ov_VkInstance instance = NULL;
    int32_t r = create_instance(&info, NULL, &instance);
    if (r != 0 || instance == NULL) {
        snprintf(report, report_len, "vkCreateInstance failed (%d)", r);
        return -4;
    }
    ov_PFN_DestroyInstance destroy_instance = (ov_PFN_DestroyInstance)gipa(instance, "vkDestroyInstance");
    ov_PFN_EnumeratePhysicalDevices enumerate = (ov_PFN_EnumeratePhysicalDevices)gipa(instance, "vkEnumeratePhysicalDevices");
    ov_PFN_GetPhysicalDeviceProperties props = (ov_PFN_GetPhysicalDeviceProperties)gipa(instance, "vkGetPhysicalDeviceProperties");
    ov_PFN_GetQueueFamilyProperties families = (ov_PFN_GetQueueFamilyProperties)gipa(instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    ov_PFN_GetSurfaceSupport support = (ov_PFN_GetSurfaceSupport)gipa(instance, "vkGetPhysicalDeviceSurfaceSupportKHR");
    ov_PFN_GetSurfaceCapabilities caps = (ov_PFN_GetSurfaceCapabilities)gipa(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");

    VkSurfaceKHR surface = 0;
    if (!api->Vulkan_CreateSurface(window, (VkInstance)instance, NULL, &surface)) {
        snprintf(report, report_len, "SDL_Vulkan_CreateSurface failed: %s", api->GetError());
        if (destroy_instance) destroy_instance(instance, NULL);
        return -5;
    }
    int presenting = 0;
    size_t used = (size_t)snprintf(report, report_len, "instance extensions %u; surface created;", (unsigned)ext_count);
    uint32_t count = 0;
    if (enumerate && enumerate(instance, &count, NULL) == 0 && count > 0) {
        ov_VkPhysicalDevice devices[16];
        if (count > 16) count = 16;
        enumerate(instance, &count, devices);
        for (uint32_t i = 0; i < count; i++) {
            /* VkPhysicalDeviceProperties: five uint32 fields, then deviceName[256]. */
            unsigned char buf[2048];
            memset(buf, 0, sizeof buf);
            if (props) props(devices[i], buf);
            const char *name = (const char *)(buf + 20);
            uint32_t nfam = 0;
            int ok = 0;
            if (families && support) {
                families(devices[i], &nfam, NULL);
                for (uint32_t q = 0; q < nfam && !ok; q++) {
                    uint32_t can = 0;
                    if (support(devices[i], q, surface, &can) == 0 && can) ok = 1;
                }
            }
            ov_VkSurfaceCapabilitiesKHR c;
            memset(&c, 0, sizeof c);
            if (ok && caps) caps(devices[i], surface, &c);
            presenting += ok;
            if (used < report_len) {
                used += (size_t)snprintf(report + used, report_len - used, " [%s: %s, extent %ux%u]", name,
                                         ok ? "presents" : "cannot present", c.currentExtent[0], c.currentExtent[1]);
            }
        }
    }
    api->Vulkan_DestroySurface((VkInstance)instance, surface, NULL);
    if (destroy_instance) destroy_instance(instance, NULL);
    return presenting;
}
