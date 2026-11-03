// Runs when the agent library is inserted into a test host (an app or
// tool started with DYLD_INSERT_LIBRARIES naming this library). The
// Swift side does nothing unless YCODE_TEST_BUNDLE is set.
// See specs/ide/testing.md, "Ycode implementation".
#include "cycodetestagentloader.h"

__attribute__((constructor)) static void ycode_test_agent_loaded(void) {
    ycode_test_agent_start();
}
