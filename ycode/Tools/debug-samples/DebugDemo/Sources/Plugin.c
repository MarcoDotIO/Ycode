// DebugDemo's plugin (specs/simulator/debug-stub.md §9): a dylib the app
// loads with dlopen during a run, for the debugger's image notifications,
// and a global the debugger can watch. Original Ycode sample code.

int demo_plugin_calls = 0;

int demo_plugin_scale(int value) {
    demo_plugin_calls += 1;
    return value * 3 + demo_plugin_calls;
}
