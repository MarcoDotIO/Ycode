// Guest probe: what the guest's networking libraries see (specs/simulator/networking-ycode.md §8).
// Prints the simulator's SystemConfiguration store (every key and value), the
// reachability flags of a name, the current Network.framework path, and the
// states of one nw_connection.
// Usage: p_netpath [host [port]]   (default example.com 80)
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import <dlfcn.h>

// SCDynamicStore exists in the iOS SystemConfiguration library, but its
// header marks it macOS-only: the functions are looked up at run time.
typedef const void *StoreRef;
typedef StoreRef (*CreateFn)(CFAllocatorRef, CFStringRef, void *, void *);
typedef CFArrayRef (*CopyKeyListFn)(StoreRef, CFStringRef);
typedef CFPropertyListRef (*CopyValueFn)(StoreRef, CFStringRef);

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        const char *host = argc > 1 ? argv[1] : "example.com";
        const char *port = argc > 2 ? argv[2] : "80";

        CreateFn storeCreate = (CreateFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCreate");
        CopyKeyListFn copyKeyList = (CopyKeyListFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyKeyList");
        CopyValueFn copyValue = (CopyValueFn)dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyValue");
        StoreRef store = storeCreate ? storeCreate(NULL, CFSTR("p_netpath"), NULL, NULL) : NULL;
        printf("store: %s\n", store ? "open" : "NULL");
        if (store) {
            NSArray *keys = CFBridgingRelease(copyKeyList(store, CFSTR(".*")));
            for (NSString *k in [keys sortedArrayUsingSelector:@selector(compare:)]) {
                id v = CFBridgingRelease(copyValue(store, (__bridge CFStringRef)k));
                NSString *text = [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                printf("key %s = %s\n", k.UTF8String, text.UTF8String);
            }
        }

        SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithName(NULL, host);
        SCNetworkReachabilityFlags flags = 0;
        Boolean got = r ? SCNetworkReachabilityGetFlags(r, &flags) : false;
        printf("reachability %s: %s flags 0x%x\n", host, got ? "ok" : "failed", flags);

        dispatch_queue_t q = dispatch_queue_create("p_netpath", NULL);
        dispatch_semaphore_t pathSeen = dispatch_semaphore_create(0);
        nw_path_monitor_t monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(monitor, q);
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            printf("path: %s status %d\n", [[(id)path description] UTF8String], nw_path_get_status(path));
            nw_path_enumerate_interfaces(path, ^bool(nw_interface_t i) {
                printf("path interface %s index %u type %d\n", nw_interface_get_name(i), nw_interface_get_index(i), nw_interface_get_type(i));
                return true;
            });
            dispatch_semaphore_signal(pathSeen);
        });
        nw_path_monitor_start(monitor);
        dispatch_semaphore_wait(pathSeen, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        nw_endpoint_t endpoint = nw_endpoint_create_host(host, port);
        nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
        nw_connection_t c = nw_connection_create(endpoint, params);
        nw_connection_set_queue(c, q);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        nw_connection_set_state_changed_handler(c, ^(nw_connection_state_t state, nw_error_t error) {
            printf("connection state %d error %d\n", state, error ? nw_error_get_error_code(error) : 0);
            if (state == nw_connection_state_ready || state == nw_connection_state_failed || state == nw_connection_state_waiting) {
                nw_path_t p = nw_connection_copy_current_path(c);
                if (p) printf("connection path: %s\n", [[(id)p description] UTF8String]);
            }
            if (state == nw_connection_state_ready || state == nw_connection_state_failed) dispatch_semaphore_signal(done);
        });
        nw_connection_start(c);
        long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
        printf("connection: %s\n", timedOut ? "timeout" : "finished");
        nw_connection_cancel(c);
        nw_path_monitor_cancel(monitor);
        return 0;
    }
}
