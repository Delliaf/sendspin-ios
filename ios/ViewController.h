//
//  ViewController.h
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//

#import <UIKit/UIKit.h>
#import "SendspinBridge.h"
#import "AudioEngine.h"
#import "SettingsViewController.h"

@interface ViewController : UIViewController <SendspinBridgeDelegate, AudioEngineDelegate, SettingsViewControllerDelegate>

@end
