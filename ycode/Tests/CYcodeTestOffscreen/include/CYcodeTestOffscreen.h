// The offscreen guard for Ycode's macOS test bundle (ycode/README.md,
// "Nothing on screen"). It is linked into every macOS test target and
// installs itself when the bundle loads, before any test runs: no window,
// panel, sheet, alert or menu of a test process reaches a display.
//
// - Every window ordered in, and every frame given to a visible window, is
//   moved to the left of all displays (only when it would touch one), and
//   AppKit's constraint to a screen is off, so it stays there. Windows order
//   in and out without AppKit's animations, which draw on a display even
//   for a window off every display.
// - App-modal alerts and panels (`runModal`, open and save panels) are not
//   shown: they return Cancel at once. Menus do not pop up. The app is not
//   activated. Finder and other apps are not asked to open anything. Each of
//   these is noted (`YcodeOffscreenSuppressed`).
// - A sentinel thread, started with the first window, checks the window
//   server every 100 ms for a window of this process on a display. It moves
//   such a window off at once, notes it (`YcodeOffscreenViolations`), and at
//   exit the process fails (status 1) naming it.
//
// `YCODE_TESTS_ON_SCREEN=1` turns all of it off, for a recording the owner
// runs by hand. Nothing in CI or an agent's run sets it.
// `YCODE_OFFSCREEN_TRACE=1` prints each window the guard moves, with the
// test frame that showed it.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the guard is installed in this process.
BOOL YcodeOffscreenIsActive(void);

/// What the guard kept off the screen instead of showing (modal alerts and
/// panels, menus, activation, files opened in other apps), one line each.
NSArray<NSString *> *YcodeOffscreenSuppressed(void);

/// Windows of this process on a display now, from the window server (one
/// line each: number, layer, bounds, alpha). Empty when none.
NSArray<NSString *> *YcodeOffscreenWindowsOnDisplays(void);

/// Every window of this process the sentinel found on a display since the
/// process started, one line each. Empty when none.
NSArray<NSString *> *YcodeOffscreenViolations(void);

/// How many times the guard moved a window off the displays.
NSInteger YcodeOffscreenParkCount(void);

/// `frame` unchanged when it touches no display, else moved left of all of
/// them (same size and height on screen).
NSRect YcodeOffscreenParkedFrame(NSRect frame);

NS_ASSUME_NONNULL_END
