//
//  ViewController.h
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//

#import <UIKit/UIKit.h>
#import "SendspinBridge.h"
#import "AudioEngine.h"

@interface ViewController : UIViewController <SendspinBridgeDelegate, AudioEngineDelegate, UIActionSheetDelegate, UIAlertViewDelegate>

@end
