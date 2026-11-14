# 1.1.14 (26)

Backup now appears below Appearance at the bottom of Settings. The version/build label is the final item. Import and export behavior is unchanged.

Notification scheduling remains identical to 1.1.13 (25), which the user reported resolved their one-minute quick-adjustment error. This release does not claim reminder-only updates for the 2, 5, 10, 15, 20, or 30-minute shared-card phase groups.

The requested broader optimization was investigated independently. The examined iOS 17 interfaces expose single-request add, full-schedule set, identifier removal, and content-only replacement. The examined reconstructed iOS 18.2 implementation removes same-identifier records on add; repeated adds collapse a phase group. Content-only replacement supplies no new trigger, while full-schedule set is not additive. Submitting only the affected group through that setter would remove unrelated pending requests. A safe scoped group replacement has not been established on iOS 17.4.1.

Evidence boundaries: iOS 17.0.3 headers establish interfaces; reconstructed iOS 18.2 code supports the implementation analysis. Neither is a device execution trace of iOS 17.4.1. Existing device tests validate the current protected full-schedule approach, not the unimplemented scoped-group alternative.

Sources:
- [iOS 17 notification center](https://github.com/MTACS/iOS-17-Runtime-Headers/blob/d1d960dfaa4107765dd7fcf891e4967c0930d5fd/Frameworks/UserNotifications.framework/UNUserNotificationCenter.h)
- [Pending-record add behavior](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/UserNotificationsCore.framework/UNCLocalNotificationClient.m#L145)
- [Notification server replacement and bulk methods](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/e26ed4563f78871c59d2d96856756a65d62517e5/System/Library/PrivateFrameworks/UserNotificationsServer.framework/UNSUserNotificationServerConnectionListener.m#L918)
