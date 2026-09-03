//
//  AppDelegate.h
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//
//  Architecture Role:
//    - Application lifecycle coordinator.
//    - Background keep-alive task management.
//    - Lock Screen and Control Center remote command listener registration.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

@end
