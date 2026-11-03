#import "SKGreeter.h"
#import "Internal/SKPrivate.h"
#import "Internal/SKProject.h"
@implementation SKGreeter
+ (NSString *)greeting { return [NSString stringWithFormat:@"SyncKit greets (%@, %@)", SK_PRIVATE_WORD, SK_PROJECT_WORD]; }
@end
