/*
 * COVSDL: OpenViews' bridge to SDL3 (round R7, 09-open-design.md §4).
 *
 * SDL3 (zlib licence, SDL3-LICENSE.txt next to this target) is not linked at
 * build time. Its public headers (release 3.4.18, the subset this bridge
 * includes; unmodified) are vendored under include/SDL3/, and the library is
 * loaded at run time with dlopen. The package therefore builds on every host
 * without SDL3 installed; the SDL back end of OVPlatform is available where a
 * libSDL3 can be found (see ov_sdl_load).
 *
 * The function table below takes each prototype from the vendored headers
 * (__typeof__), so the calls are type-checked against SDL's declarations.
 */
#ifndef OV_SDL_H
#define OV_SDL_H

#include <stddef.h>
#include <stdint.h>

#include <SDL3/SDL_init.h>
#include <SDL3/SDL_video.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_vulkan.h>
#include <SDL3/SDL_clipboard.h>
#include <SDL3/SDL_keyboard.h>
#include <SDL3/SDL_mouse.h>
#include <SDL3/SDL_surface.h>
#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_error.h>
#include <SDL3/SDL_timer.h>
#include <SDL3/SDL_misc.h>
#include <SDL3/SDL_hints.h>
#include <SDL3/SDL_version.h>

#define OV_SDL_FN(name) __typeof__(SDL_##name) *name

typedef struct OVSDLAPI {
    OV_SDL_FN(Init);
    OV_SDL_FN(Quit);
    OV_SDL_FN(GetError);
    OV_SDL_FN(SetHint);
    OV_SDL_FN(GetVersion);
    OV_SDL_FN(GetCurrentVideoDriver);
    OV_SDL_FN(CreateWindow);
    OV_SDL_FN(CreatePopupWindow);
    OV_SDL_FN(DestroyWindow);
    OV_SDL_FN(GetWindowID);
    OV_SDL_FN(GetWindowSize);
    OV_SDL_FN(SetWindowSize);
    OV_SDL_FN(GetWindowSizeInPixels);
    OV_SDL_FN(GetWindowDisplayScale);
    OV_SDL_FN(SetWindowTitle);
    OV_SDL_FN(ShowWindow);
    OV_SDL_FN(GetWindowProperties);
    OV_SDL_FN(GetPointerProperty);
    OV_SDL_FN(GetNumberProperty);
    OV_SDL_FN(GetDisplayForWindow);
    OV_SDL_FN(GetCurrentDisplayMode);
    OV_SDL_FN(GetDisplayUsableBounds);
    OV_SDL_FN(SetWindowPosition);
    OV_SDL_FN(RaiseWindow);
    OV_SDL_FN(GetWindowSurface);
    OV_SDL_FN(UpdateWindowSurface);
    OV_SDL_FN(CreateSurfaceFrom);
    OV_SDL_FN(DestroySurface);
    OV_SDL_FN(ConvertSurface);
    OV_SDL_FN(LockSurface);
    OV_SDL_FN(UnlockSurface);
    OV_SDL_FN(BlitSurface);
    OV_SDL_FN(PollEvent);
    OV_SDL_FN(WaitEventTimeout);
    OV_SDL_FN(PushEvent);
    OV_SDL_FN(PumpEvents);
    OV_SDL_FN(HasEvents);
    OV_SDL_FN(RegisterEvents);
    OV_SDL_FN(StartTextInput);
    OV_SDL_FN(StopTextInput);
    OV_SDL_FN(SetTextInputArea);
    OV_SDL_FN(SetClipboardText);
    OV_SDL_FN(GetClipboardText);
    OV_SDL_FN(HasClipboardText);
    OV_SDL_FN(free);
    OV_SDL_FN(OpenURL);
    OV_SDL_FN(GetTicksNS);
    OV_SDL_FN(Vulkan_GetInstanceExtensions);
    OV_SDL_FN(Vulkan_CreateSurface);
    OV_SDL_FN(Vulkan_DestroySurface);
    OV_SDL_FN(Vulkan_GetVkGetInstanceProcAddr);
    OV_SDL_FN(Vulkan_LoadLibrary);
    /* R10/R11 */
    OV_SDL_FN(GetSystemTheme);
    OV_SDL_FN(MinimizeWindow);
    /* AT-SPI export */
    OV_SDL_FN(GetWindowPosition);
    /* Client-side window decorations (B5): hit testing for moves and
       resizes, the zoom button's maximise and full screen. */
    OV_SDL_FN(SetWindowHitTest);
    OV_SDL_FN(GetWindowFlags);
    OV_SDL_FN(MaximizeWindow);
    OV_SDL_FN(RestoreWindow);
    OV_SDL_FN(SetWindowFullscreen);
} OVSDLAPI;

#undef OV_SDL_FN

/* Window flags (the SDL macros use SDL_UINT64_C, which Swift cannot import). */
static const uint64_t OV_SDL_WINDOW_RESIZABLE = SDL_WINDOW_RESIZABLE;
static const uint64_t OV_SDL_WINDOW_HIGH_PIXEL_DENSITY = SDL_WINDOW_HIGH_PIXEL_DENSITY;
static const uint64_t OV_SDL_WINDOW_VULKAN = SDL_WINDOW_VULKAN;
static const uint64_t OV_SDL_WINDOW_HIDDEN = SDL_WINDOW_HIDDEN;
static const uint64_t OV_SDL_WINDOW_POPUP_MENU = SDL_WINDOW_POPUP_MENU;
static const uint64_t OV_SDL_WINDOW_NOT_FOCUSABLE = SDL_WINDOW_NOT_FOCUSABLE;
static const uint64_t OV_SDL_WINDOW_BORDERLESS = SDL_WINDOW_BORDERLESS;
static const uint64_t OV_SDL_WINDOW_MAXIMIZED = SDL_WINDOW_MAXIMIZED;
static const uint64_t OV_SDL_WINDOW_FULLSCREEN = SDL_WINDOW_FULLSCREEN;

/*
 * Loads libSDL3 and resolves the table. `path` may be NULL: then the
 * OV_SDL3_LIBRARY environment variable, the dynamic loader's search path
 * (LD_LIBRARY_PATH, rpath; DYLD paths on Apple hosts) and the usual user and
 * Homebrew prefixes are tried. Returns NULL and writes a reason into `error`
 * when no usable library is found. The table is loaded once per process.
 */
const OVSDLAPI *ov_sdl_load(const char *path, char *error, size_t error_len);

/* The library file that was loaded (empty before a successful load). */
const char *ov_sdl_loaded_path(void);

/*
 * The file descriptor of the window system connection behind `window` (the
 * X11 display or the Wayland display), or -1. The run loop watches it so it
 * can sleep until either the window system or the main queue has work.
 */
int ov_sdl_display_fd(const OVSDLAPI *api, SDL_Window *window);

/*
 * Gives an X11 window the keyboard focus (XSetInputFocus through SDL's own
 * libX11). Returns 1 when done, 0 on other window systems. Used when a pop-up
 * menu closes: without a window manager the focus fell to the root window.
 */
int ov_sdl_x11_focus(const OVSDLAPI *api, SDL_Window *window);

/*
 * Checks the Vulkan surface path of a window created with SDL_WINDOW_VULKAN:
 * creates an instance with the extensions SDL requires, a surface for the
 * window, and asks every physical device whether a queue family can present
 * to it. Writes a one-line report (device names, supported families, the
 * surface's current extent) into `report`. Returns the number of devices that
 * can present, or a negative value on failure. Vulkan structures are declared
 * locally (Vulkan API, Khronos registry), so no Vulkan headers are needed.
 */
int ov_vk_probe_surface(const OVSDLAPI *api, SDL_Window *window, char *report, size_t report_len);

#endif
