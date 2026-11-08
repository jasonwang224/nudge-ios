#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN
BOOL NudgeExpirationAvailable(void);
BOOL NudgeSetExpiration(UNMutableNotificationContent *content, NSDate * _Nullable date);
BOOL NudgeExpirationMatches(UNNotificationContent *content, NSDate * _Nullable date);
NSDate * _Nullable NudgeReadExpiration(UNNotificationContent *content);
NS_ASSUME_NONNULL_END
