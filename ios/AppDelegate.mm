//
//  AppDelegate.mm
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "AudioEngine.h"
#import "SendspinBridge.h"
#import <MediaPlayer/MediaPlayer.h>

@interface AppDelegate () {
    UIBackgroundTaskIdentifier _bgTask;
}
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    ViewController *mainVC = [[ViewController alloc] init];
    
    // Support iOS 3 - 9 window rootViewController
    if ([self.window respondsToSelector:@selector(setRootViewController:)]) {
        self.window.rootViewController = mainVC;
    } else {
        [self.window addSubview:mainVC.view];
    }
    [self.window makeKeyAndVisible];

    // Configure Lockscreen & Remote controls (iOS 4.0 - 9.3+)
    [self setupRemoteControlCommands];
    
    // Read Keep-Alive preference (default: YES)
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"SendspinBackgroundKeepAlive"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"SendspinBackgroundKeepAlive"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    BOOL keepAlive = [[NSUserDefaults standardUserDefaults] boolForKey:@"SendspinBackgroundKeepAlive"];
    [AudioEngine sharedInstance].keepAliveEnabled = keepAlive;

    // Setup Audio Session for background playback asynchronously so app opens instantly
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AudioEngine sharedInstance] setupAudioSessionWithError:nil];
        if (keepAlive) {
            [[AudioEngine sharedInstance] start];
        }
    });

    return YES;
}

- (void)setupRemoteControlCommands {
    // 1. Modern iOS 7.1+ MPRemoteCommandCenter
    if (NSClassFromString(@"MPRemoteCommandCenter")) {
        MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];

        commandCenter.playCommand.enabled = YES;
        [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [[SendspinBridge sharedInstance] play];
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        commandCenter.pauseCommand.enabled = YES;
        [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [[SendspinBridge sharedInstance] pause];
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        commandCenter.togglePlayPauseCommand.enabled = YES;
        [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [[SendspinBridge sharedInstance] togglePlayPause];
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        commandCenter.nextTrackCommand.enabled = YES;
        [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [[SendspinBridge sharedInstance] nextTrack];
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        commandCenter.previousTrackCommand.enabled = YES;
        [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            [[SendspinBridge sharedInstance] previousTrack];
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        if ([commandCenter respondsToSelector:@selector(changePlaybackPositionCommand)]) {
            [commandCenter.changePlaybackPositionCommand setEnabled:YES];
            [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
                if ([event isKindOfClass:NSClassFromString(@"MPChangePlaybackPositionCommandEvent")]) {
                    MPChangePlaybackPositionCommandEvent *posEvent = (MPChangePlaybackPositionCommandEvent *)event;
                    uint32_t posMs = (uint32_t)(posEvent.positionTime * 1000.0);
                    [[SendspinBridge sharedInstance] seekToMs:posMs];
                    return MPRemoteCommandHandlerStatusSuccess;
                }
                return MPRemoteCommandHandlerStatusCommandFailed;
            }];
        }
    }

    // 2. Legacy iOS 4.0 - 7.0 remote control events registration
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]) {
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    BOOL keepAlive = [[NSUserDefaults standardUserDefaults] boolForKey:@"SendspinBackgroundKeepAlive"];
    if (keepAlive) {
        [[AudioEngine sharedInstance] start];
    }
    
    if ([application respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) {
        _bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
            [application endBackgroundTask:self->_bgTask];
            self->_bgTask = UIBackgroundTaskInvalid;
        }];
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    if ([application respondsToSelector:@selector(endBackgroundTask:)]) {
        if (_bgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:_bgTask];
            _bgTask = UIBackgroundTaskInvalid;
        }
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[SendspinBridge sharedInstance] stop];
    [[AudioEngine sharedInstance] stop];
}

@end
