//
//  main.m
//  Sendspin iOS Player
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        freopen("/var/mobile/sendspin.log", "w", stdout);
        freopen("/var/mobile/sendspin.log", "w", stderr);
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
        NSLog(@"=== Sendspin Started ===");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
