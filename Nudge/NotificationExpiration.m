#import "NotificationExpiration.h"

// Experimental private property. Never assume it exists or that a setter
// accepted by this process will be honored by iOS after scheduling.
BOOL NudgeExpirationAvailable(void) {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    return [content respondsToSelector:NSSelectorFromString(@"setExpirationDate:")]
        && [content respondsToSelector:NSSelectorFromString(@"expirationDate")];
}

NSDate *NudgeReadExpiration(UNNotificationContent *content) {
    @try {
        if (![content respondsToSelector:NSSelectorFromString(@"expirationDate")]) return nil;
        id value = [content valueForKey:@"expirationDate"];
        return [value isKindOfClass:NSDate.class] ? value : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

BOOL NudgeSetExpiration(UNMutableNotificationContent *content, NSDate *date) {
    @try {
        if (!NudgeExpirationAvailable()) return NO;
        [content setValue:date forKey:@"expirationDate"];
        return NudgeExpirationMatches(content, date);
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL NudgeExpirationMatches(UNNotificationContent *content, NSDate *date) {
    @try {
        if (![content respondsToSelector:NSSelectorFromString(@"expirationDate")]) return NO;
        id actual = [content valueForKey:@"expirationDate"];
        return date ? [actual isKindOfClass:NSDate.class] && [actual isEqualToDate:date] : actual == nil;
    } @catch (NSException *exception) {
        return NO; // A failed read is not proof that an expiry was removed.
    }
}
