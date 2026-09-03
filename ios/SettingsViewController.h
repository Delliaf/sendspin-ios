//
//  SettingsViewController.h
//  Sendspin Universal iOS Player
//

#import <UIKit/UIKit.h>
#import "SendspinBridge.h"
#import "AudioEngine.h"

@protocol SettingsViewControllerDelegate <NSObject>
- (void)settingsDidRequestDismiss;
@end

@interface SettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>

@property (nonatomic, weak) id<SettingsViewControllerDelegate> delegate;

@end
