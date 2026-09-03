//
//  ViewController.h
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//
//  Architecture Role:
//    - Primary user interface for iPhone & iPad (Hi-Fi Retina dark theme).
//    - Native vector media transport buttons (Play/Pause, Prev, Next, Volume).
//    - Real-time progress bar interpolation and fine sync latency adjustment.
//    - Server discovery and manual IP connection dialogs (UIAlertController / UIActionSheet).
//

#import <UIKit/UIKit.h>
#import "SendspinBridge.h"
#import "AudioEngine.h"

@interface ViewController : UIViewController <SendspinBridgeDelegate, AudioEngineDelegate, UIActionSheetDelegate, UIAlertViewDelegate>

@end
