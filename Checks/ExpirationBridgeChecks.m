#import "../Nudge/NotificationExpiration.h"
#include <stdio.h>

@interface ThrowingContent : UNMutableNotificationContent
@end
@implementation ThrowingContent
- (BOOL)respondsToSelector:(SEL)selector { return YES; }
- (id)valueForKey:(NSString *)key { @throw [NSException exceptionWithName:@"ReadFailure" reason:@"test" userInfo:nil]; }
- (void)setValue:(id)value forKey:(NSString *)key { @throw [NSException exceptionWithName:@"WriteFailure" reason:@"test" userInfo:nil]; }
@end

int main(void) {
    @autoreleasepool {
        ThrowingContent *content = [ThrowingContent new];
        NSCAssert(NudgeReadExpiration(content) == nil, @"Read failures must not escape into Swift");
        NSCAssert(!NudgeExpirationMatches(content, nil), @"Failed reads cannot verify removal");
        NSCAssert(!NudgeSetExpiration(content, nil), @"Failed writes cannot verify removal");
        NSCAssert(!NudgeSetExpiration(content, [NSDate date]), @"Failed writes cannot arm expiration");
        puts("Objective-C exception containment checks passed.");
    }
}
