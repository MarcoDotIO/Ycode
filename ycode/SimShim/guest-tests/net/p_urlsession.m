// Guest probe: an NSURLSession data task (specs/simulator/networking-ycode.md §8).
// Usage: p_urlsession [url ...]   (default https://example.com/)
// Prints "ok URLSession <url>: status N, B bytes, T s" or "FAIL ..." per URL.
#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [urls addObject:[NSString stringWithUTF8String:argv[i]]];
        if (urls.count == 0) [urls addObject:@"https://example.com/"];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        int failures = 0;
        for (NSString *u in urls) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSInteger status = -1;
            __block NSUInteger bytes = 0;
            __block NSError *error = nil;
            NSDate *start = [NSDate date];
            NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:u]
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *e) {
                status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
                bytes = data.length;
                error = e;
                dispatch_semaphore_signal(done);
            }];
            [task resume];
            long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
            double t = -[start timeIntervalSinceNow];
            if (!timedOut && !error && status >= 200 && status < 400) {
                printf("ok URLSession %s: status %ld, %lu bytes, %.2f s\n", u.UTF8String, (long)status, (unsigned long)bytes, t);
            } else {
                failures++;
                printf("FAIL URLSession %s: %s status %ld error %s (%ld) after %.2f s\n", u.UTF8String, timedOut ? "timeout" : "",
                       (long)status, error.domain.UTF8String ?: "-", (long)error.code, t);
                if (error) printf("note %s\n", error.description.UTF8String);
            }
        }
        return failures ? 1 : 0;
    }
}
