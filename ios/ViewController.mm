//
//  ViewController.mm
//  Sendspin Universal iOS Player (iOS 3.0 — iOS 9.3+)
//

#import "ViewController.h"
#import <MediaPlayer/MediaPlayer.h>

@interface ViewController () {
    UIView *_topBarView;
    UIView *_statusDot;
    UILabel *_statusLabel;
    UIButton *_settingsButton;
    
    UIView *_coverCardView;
    UIImageView *_coverImageView;
    UILabel *_titleLabel;
    UILabel *_artistAlbumLabel;
    
    UISlider *_progressSlider;
    UILabel *_currentTimeLabel;
    UILabel *_totalTimeLabel;
    
    UIButton *_prevButton;
    UIButton *_playPauseButton;
    UIButton *_nextButton;
    
    UIImageView *_volMinIcon;
    UISlider *_volumeSlider;
    UIImageView *_volMaxIcon;
    
    UIView *_delayContainerView;
    UILabel *_delayLabel;
    UIButton *_delayMinus10Button;
    UIButton *_delayMinus1Button;
    UIButton *_delayPlus1Button;
    UIButton *_delayPlus10Button;
    UIButton *_delayResetButton;
    
    NSTimer *_progressTimer;
    NSTimeInterval _lastMetadataTimestamp;
    uint32_t _baseProgressMs;
    BOOL _isUserScrubbing;
    NSArray<NSDictionary *> *_discoveredServers;
}
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    
    [SendspinBridge sharedInstance].delegate = self;
    [AudioEngine sharedInstance].delegate = self;
    
    [self setupUI];
    [self updateStatusDisplay];
    [self updateNowPlayingDisplay];
    [self updateDelayDisplay];
    
    BOOL keepAwake = [[NSUserDefaults standardUserDefaults] boolForKey:@"SendspinKeepScreenAwake"];
    [UIApplication sharedApplication].idleTimerDisabled = keepAwake;

    NSString *savedName = [[NSUserDefaults standardUserDefaults] stringForKey:@"SendspinPlayerName"];
    if (!savedName || savedName.length == 0) {
        savedName = @"Sendspin Player";
    }
    NSInteger savedPort = [[NSUserDefaults standardUserDefaults] integerForKey:@"SendspinServerPort"];
    if (savedPort <= 0) savedPort = 8928;
    
    [[SendspinBridge sharedInstance] startServiceWithName:savedName port:(uint16_t)savedPort];
    [[SendspinBridge sharedInstance] startBonjourDiscovery];

    // Start smooth progress timer (5Hz)
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                      target:self
                                                    selector:@selector(onProgressTimerTick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Enable remote control events for iOS 4.0 - 7.0 lockscreen / home double-tap bar
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(beginReceivingRemoteControlEvents)]) {
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }
    [self becomeFirstResponder];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type == UIEventTypeRemoteControl) {
        switch (event.subtype) {
            case UIEventSubtypeRemoteControlPlay:
                [[SendspinBridge sharedInstance] play];
                break;
            case UIEventSubtypeRemoteControlPause:
                [[SendspinBridge sharedInstance] pause];
                break;
            case UIEventSubtypeRemoteControlTogglePlayPause:
                [[SendspinBridge sharedInstance] togglePlayPause];
                break;
            case UIEventSubtypeRemoteControlNextTrack:
                [[SendspinBridge sharedInstance] nextTrack];
                break;
            case UIEventSubtypeRemoteControlPreviousTrack:
                [[SendspinBridge sharedInstance] previousTrack];
                break;
            default:
                break;
        }
    }
}

- (void)dealloc {
    [_progressTimer invalidate];
    _progressTimer = nil;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)setupUI {
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;
    if (screenW > screenH) {
        CGFloat temp = screenW; screenW = screenH; screenH = temp;
    }
    
    // 1. Top Header Bar
    _topBarView = [[UIView alloc] initWithFrame:CGRectMake(0, 20, screenW, 40)];
    _topBarView.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
    _topBarView.layer.borderWidth = 0.5;
    _topBarView.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:0.6].CGColor;
    [self.view addSubview:_topBarView];
    
    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(12, 15, 10, 10)];
    _statusDot.layer.cornerRadius = 5.0;
    _statusDot.backgroundColor = [UIColor colorWithRed:0.3 green:0.75 blue:0.95 alpha:1.0];
    [_topBarView addSubview:_statusDot];
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 8, screenW - 110, 24)];
    _statusLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    _statusLabel.font = [UIFont boldSystemFontOfSize:12];
    _statusLabel.text = @"Port 8928 (mDNS Active)";
    [_topBarView addSubview:_statusLabel];
    
    _settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _settingsButton.frame = CGRectMake(screenW - 76, 7, 66, 26);
    _settingsButton.layer.cornerRadius = 4.0;
    _settingsButton.layer.borderWidth = 1.0;
    _settingsButton.layer.borderColor = [UIColor colorWithRed:0.85 green:0.75 blue:0.45 alpha:0.7].CGColor;
    _settingsButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [_settingsButton setTitle:@"⚙ Server" forState:UIControlStateNormal];
    [_settingsButton setTitleColor:[UIColor colorWithRed:0.95 green:0.85 blue:0.55 alpha:1.0] forState:UIControlStateNormal];
    [_settingsButton addTarget:self action:@selector(showServerDialog) forControlEvents:UIControlEventTouchUpInside];
    [_topBarView addSubview:_settingsButton];
    
    // 2. Cover Art Card View
    CGFloat coverSize = 168.0;
    CGFloat coverY = 68.0;
    _coverCardView = [[UIView alloc] initWithFrame:CGRectMake((screenW - coverSize) / 2.0, coverY, coverSize, coverSize)];
    _coverCardView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    _coverCardView.layer.cornerRadius = 8.0;
    _coverCardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _coverCardView.layer.shadowOffset = CGSizeMake(0, 4);
    _coverCardView.layer.shadowOpacity = 0.5;
    _coverCardView.layer.shadowRadius = 6.0;
    [self.view addSubview:_coverCardView];
    
    _coverImageView = [[UIImageView alloc] initWithFrame:_coverCardView.bounds];
    _coverImageView.layer.cornerRadius = 8.0;
    _coverImageView.layer.masksToBounds = YES;
    _coverImageView.layer.borderWidth = 0.5;
    _coverImageView.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
    _coverImageView.contentMode = UIViewContentModeScaleAspectFill;
    _coverImageView.image = [self generatePlaceholderArtwork];
    [_coverCardView addSubview:_coverImageView];
    
    // 3. Track Title & Artist / Album Labels
    CGFloat titleY = 244.0;
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, titleY, screenW - 32, 22)];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:16];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = @"Sendspin Player";
    [self.view addSubview:_titleLabel];
    
    _artistAlbumLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, titleY + 22, screenW - 32, 18)];
    _artistAlbumLabel.textColor = [UIColor colorWithRed:0.85 green:0.75 blue:0.55 alpha:0.9];
    _artistAlbumLabel.font = [UIFont systemFontOfSize:12];
    _artistAlbumLabel.textAlignment = NSTextAlignmentCenter;
    _artistAlbumLabel.text = @"Ready to Stream";
    [self.view addSubview:_artistAlbumLabel];
    
    // 4. Progress Slider & Timers
    CGFloat progressY = titleY + 44.0;
    _progressSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, progressY, screenW - 32, 18)];
    _progressSlider.minimumValue = 0.0;
    _progressSlider.maximumValue = 1.0;
    _progressSlider.value = 0.0;
    _progressSlider.tintColor = [UIColor colorWithRed:0.85 green:0.75 blue:0.45 alpha:1.0];
    [_progressSlider addTarget:self action:@selector(onProgressSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_progressSlider addTarget:self action:@selector(onProgressSliderTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.view addSubview:_progressSlider];
    
    _currentTimeLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, progressY + 18, 60, 14)];
    _currentTimeLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _currentTimeLabel.font = [UIFont systemFontOfSize:10];
    _currentTimeLabel.text = @"0:00";
    [self.view addSubview:_currentTimeLabel];
    
    _totalTimeLabel = [[UILabel alloc] initWithFrame:CGRectMake(screenW - 76, progressY + 18, 60, 14)];
    _totalTimeLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _totalTimeLabel.font = [UIFont systemFontOfSize:10];
    _totalTimeLabel.textAlignment = NSTextAlignmentRight;
    _totalTimeLabel.text = @"0:00";
    [self.view addSubview:_totalTimeLabel];
    
    // 5. Playback Transport Bar with Native Vector Glyphs
    CGFloat btnY = progressY + 34.0;
    CGFloat btnW = 50.0;
    _prevButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _prevButton.frame = CGRectMake((screenW / 2.0) - btnW - 36, btnY, btnW, 40);
    [_prevButton setImage:[self generatePrevIconInColor:[UIColor whiteColor] size:CGSizeMake(26, 20)] forState:UIControlStateNormal];
    [_prevButton addTarget:self action:@selector(onPrevPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_prevButton];
    
    _playPauseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _playPauseButton.frame = CGRectMake((screenW - 54) / 2.0, btnY - 3, 54, 46);
    _playPauseButton.backgroundColor = [UIColor colorWithRed:0.85 green:0.75 blue:0.45 alpha:0.95];
    _playPauseButton.layer.cornerRadius = 23.0;
    _playPauseButton.layer.shadowColor = [UIColor blackColor].CGColor;
    _playPauseButton.layer.shadowOffset = CGSizeMake(0, 2);
    _playPauseButton.layer.shadowOpacity = 0.4;
    _playPauseButton.layer.shadowRadius = 4.0;
    [_playPauseButton setImage:[self generatePlayIconInColor:[UIColor blackColor] size:CGSizeMake(22, 22)] forState:UIControlStateNormal];
    [_playPauseButton addTarget:self action:@selector(onPlayPausePressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playPauseButton];
    
    _nextButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _nextButton.frame = CGRectMake((screenW / 2.0) + 36, btnY, btnW, 40);
    [_nextButton setImage:[self generateNextIconInColor:[UIColor whiteColor] size:CGSizeMake(26, 20)] forState:UIControlStateNormal];
    [_nextButton addTarget:self action:@selector(onNextPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextButton];
    
    // 6. Volume Slider
    CGFloat volY = btnY + 48.0;
    _volMinIcon = [[UIImageView alloc] initWithFrame:CGRectMake(16, volY + 2, 16, 16)];
    _volMinIcon.image = [self generateSpeakerIconSmall];
    [self.view addSubview:_volMinIcon];
    
    _volumeSlider = [[UISlider alloc] initWithFrame:CGRectMake(38, volY, screenW - 76, 20)];
    _volumeSlider.minimumValue = 0.0;
    _volumeSlider.maximumValue = 1.0;
    _volumeSlider.value = [SendspinBridge sharedInstance].currentVolume;
    _volumeSlider.tintColor = [UIColor colorWithRed:0.35 green:0.75 blue:0.95 alpha:1.0];
    [_volumeSlider addTarget:self action:@selector(onVolumeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_volumeSlider];
    
    _volMaxIcon = [[UIImageView alloc] initWithFrame:CGRectMake(screenW - 32, volY + 2, 16, 16)];
    _volMaxIcon.image = [self generateSpeakerIconLarge];
    [self.view addSubview:_volMaxIcon];
    
    // 7. Sync Delay Fine Tuning Panel
    CGFloat delayY = volY + 28.0;
    _delayContainerView = [[UIView alloc] initWithFrame:CGRectMake(8, delayY, screenW - 16, 36)];
    _delayContainerView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.95];
    _delayContainerView.layer.cornerRadius = 6.0;
    _delayContainerView.layer.borderWidth = 0.5;
    _delayContainerView.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.7].CGColor;
    [self.view addSubview:_delayContainerView];
    
    _delayLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 8, 88, 20)];
    _delayLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _delayLabel.font = [UIFont boldSystemFontOfSize:10];
    _delayLabel.text = @"Sync: 0 ms";
    [_delayContainerView addSubview:_delayLabel];
    
    CGFloat cW = _delayContainerView.bounds.size.width;
    CGFloat btnPad = 4.0;
    CGFloat dBtnW = 38.0;
    CGFloat dBtnH = 24.0;
    CGFloat dBtnY = 6.0;
    
    _delayMinus10Button = [UIButton buttonWithType:UIButtonTypeCustom];
    _delayMinus10Button.frame = CGRectMake(cW - (dBtnW * 5 + btnPad * 4) - 4, dBtnY, dBtnW, dBtnH);
    _delayMinus10Button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _delayMinus10Button.layer.cornerRadius = 3.0;
    [_delayMinus10Button setTitle:@"-10" forState:UIControlStateNormal];
    _delayMinus10Button.titleLabel.font = [UIFont boldSystemFontOfSize:9];
    [_delayMinus10Button addTarget:self action:@selector(onDelayMinus10) forControlEvents:UIControlEventTouchUpInside];
    [_delayContainerView addSubview:_delayMinus10Button];
    
    _delayMinus1Button = [UIButton buttonWithType:UIButtonTypeCustom];
    _delayMinus1Button.frame = CGRectMake(cW - (dBtnW * 4 + btnPad * 3) - 4, dBtnY, dBtnW, dBtnH);
    _delayMinus1Button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _delayMinus1Button.layer.cornerRadius = 3.0;
    [_delayMinus1Button setTitle:@"-1" forState:UIControlStateNormal];
    _delayMinus1Button.titleLabel.font = [UIFont boldSystemFontOfSize:9];
    [_delayMinus1Button addTarget:self action:@selector(onDelayMinus1) forControlEvents:UIControlEventTouchUpInside];
    [_delayContainerView addSubview:_delayMinus1Button];
    
    _delayPlus1Button = [UIButton buttonWithType:UIButtonTypeCustom];
    _delayPlus1Button.frame = CGRectMake(cW - (dBtnW * 3 + btnPad * 2) - 4, dBtnY, dBtnW, dBtnH);
    _delayPlus1Button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _delayPlus1Button.layer.cornerRadius = 3.0;
    [_delayPlus1Button setTitle:@"+1" forState:UIControlStateNormal];
    _delayPlus1Button.titleLabel.font = [UIFont boldSystemFontOfSize:9];
    [_delayPlus1Button addTarget:self action:@selector(onDelayPlus1) forControlEvents:UIControlEventTouchUpInside];
    [_delayContainerView addSubview:_delayPlus1Button];
    
    _delayPlus10Button = [UIButton buttonWithType:UIButtonTypeCustom];
    _delayPlus10Button.frame = CGRectMake(cW - (dBtnW * 2 + btnPad * 1) - 4, dBtnY, dBtnW, dBtnH);
    _delayPlus10Button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _delayPlus10Button.layer.cornerRadius = 3.0;
    [_delayPlus10Button setTitle:@"+10" forState:UIControlStateNormal];
    _delayPlus10Button.titleLabel.font = [UIFont boldSystemFontOfSize:9];
    [_delayPlus10Button addTarget:self action:@selector(onDelayPlus10) forControlEvents:UIControlEventTouchUpInside];
    [_delayContainerView addSubview:_delayPlus10Button];
    
    _delayResetButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _delayResetButton.frame = CGRectMake(cW - dBtnW - 4, dBtnY, dBtnW, dBtnH);
    _delayResetButton.backgroundColor = [UIColor colorWithRed:0.7 green:0.6 blue:0.35 alpha:0.8];
    _delayResetButton.layer.cornerRadius = 3.0;
    [_delayResetButton setTitle:@"0" forState:UIControlStateNormal];
    _delayResetButton.titleLabel.font = [UIFont boldSystemFontOfSize:9];
    [_delayResetButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [_delayResetButton addTarget:self action:@selector(onDelayReset) forControlEvents:UIControlEventTouchUpInside];
    [_delayContainerView addSubview:_delayResetButton];

    UILabel *versionBadge = [[UILabel alloc] initWithFrame:CGRectMake(0, screenH - 12, screenW - 6, 10)];
    versionBadge.font = [UIFont systemFontOfSize:8];
    versionBadge.textColor = [UIColor colorWithWhite:0.4 alpha:0.8];
    versionBadge.textAlignment = NSTextAlignmentRight;
    versionBadge.text = @"Sendspin v1.0.1 (b107)";
    [self.view addSubview:versionBadge];
}

#pragma mark - Native Vector Glyphs

- (UIImage *)generatePlayIconInColor:(UIColor *)color size:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, 5, 2);
    CGPathAddLineToPoint(path, NULL, size.width - 3, size.height / 2.0);
    CGPathAddLineToPoint(path, NULL, 5, size.height - 2);
    CGPathCloseSubpath(path);
    
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generatePauseIconInColor:(UIColor *)color size:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    
    CGFloat barW = 5.0;
    CGFloat barH = size.height - 6;
    CGFloat gap = 6.0;
    CGFloat x1 = (size.width - (barW * 2 + gap)) / 2.0;
    CGFloat x2 = x1 + barW + gap;
    CGFloat y = 3.0;
    
    UIBezierPath *p1 = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x1, y, barW, barH) cornerRadius:1.5];
    UIBezierPath *p2 = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x2, y, barW, barH) cornerRadius:1.5];
    [p1 fill];
    [p2 fill];
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generateNextIconInColor:(UIColor *)color size:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    
    CGMutablePathRef p1 = CGPathCreateMutable();
    CGPathMoveToPoint(p1, NULL, 2, 3);
    CGPathAddLineToPoint(p1, NULL, 11, size.height / 2.0);
    CGPathAddLineToPoint(p1, NULL, 2, size.height - 3);
    CGPathCloseSubpath(p1);
    CGContextAddPath(ctx, p1);
    CGContextFillPath(ctx);
    CGPathRelease(p1);
    
    CGMutablePathRef p2 = CGPathCreateMutable();
    CGPathMoveToPoint(p2, NULL, 11, 3);
    CGPathAddLineToPoint(p2, NULL, 20, size.height / 2.0);
    CGPathAddLineToPoint(p2, NULL, 11, size.height - 3);
    CGPathCloseSubpath(p2);
    CGContextAddPath(ctx, p2);
    CGContextFillPath(ctx);
    CGPathRelease(p2);
    
    UIBezierPath *bar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(21, 3, 3, size.height - 6) cornerRadius:1.0];
    [bar fill];
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generatePrevIconInColor:(UIColor *)color size:(CGSize)size {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, color.CGColor);
    
    UIBezierPath *bar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, 3, size.height - 6) cornerRadius:1.0];
    [bar fill];
    
    CGMutablePathRef p1 = CGPathCreateMutable();
    CGPathMoveToPoint(p1, NULL, 15, 3);
    CGPathAddLineToPoint(p1, NULL, 6, size.height / 2.0);
    CGPathAddLineToPoint(p1, NULL, 15, size.height - 3);
    CGPathCloseSubpath(p1);
    CGContextAddPath(ctx, p1);
    CGContextFillPath(ctx);
    CGPathRelease(p1);
    
    CGMutablePathRef p2 = CGPathCreateMutable();
    CGPathMoveToPoint(p2, NULL, 24, 3);
    CGPathAddLineToPoint(p2, NULL, 15, size.height / 2.0);
    CGPathAddLineToPoint(p2, NULL, 24, size.height - 3);
    CGPathCloseSubpath(p2);
    CGContextAddPath(ctx, p2);
    CGContextFillPath(ctx);
    CGPathRelease(p2);
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generatePlaceholderArtwork {
    CGSize size = CGSizeMake(300, 300);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    
    CGContextSetRGBFillColor(ctx, 0.13, 0.14, 0.17, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, 300, 300));
    
    CGContextSetRGBStrokeColor(ctx, 0.85, 0.75, 0.45, 0.8);
    CGContextSetLineWidth(ctx, 3.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(40, 40, 220, 220));
    
    CGContextSetRGBStrokeColor(ctx, 0.3, 0.32, 0.38, 0.8);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(70, 70, 160, 160));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(100, 100, 100, 100));
    
    CGContextSetRGBFillColor(ctx, 0.85, 0.75, 0.45, 1.0);
    CGContextFillEllipseInRect(ctx, CGRectMake(125, 125, 50, 50));
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generateSpeakerIconSmall {
    CGSize size = CGSizeMake(16, 16);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBFillColor(ctx, 0.6, 0.65, 0.75, 1.0);
    CGContextFillRect(ctx, CGRectMake(2, 5, 4, 6));
    
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, 6, 5);
    CGPathAddLineToPoint(path, NULL, 11, 2);
    CGPathAddLineToPoint(path, NULL, 11, 14);
    CGPathAddLineToPoint(path, NULL, 6, 11);
    CGPathCloseSubpath(path);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UIImage *)generateSpeakerIconLarge {
    CGSize size = CGSizeMake(16, 16);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    
    UIImage *small = [self generateSpeakerIconSmall];
    [small drawInRect:CGRectMake(0, 0, 16, 16)];
    
    CGContextSetRGBStrokeColor(ctx, 0.6, 0.65, 0.75, 1.0);
    CGContextSetLineWidth(ctx, 1.2);
    CGContextAddArc(ctx, 10, 8, 4, -0.6, 0.6, 0);
    CGContextStrokePath(ctx);
    
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (NSString *)formatTimeMs:(uint32_t)ms {
    uint32_t totalSec = ms / 1000;
    uint32_t min = totalSec / 60;
    uint32_t sec = totalSec % 60;
    return [NSString stringWithFormat:@"%u:%02u", min, sec];
}

- (void)onProgressTimerTick {
    SendspinBridge *bridge = [SendspinBridge sharedInstance];
    if (!_isUserScrubbing && bridge.currentDurationMs > 0) {
        uint32_t progress = _baseProgressMs;
        if (bridge.playbackState == SendspinPlaybackStatePlaying && _lastMetadataTimestamp > 0) {
            NSTimeInterval delta = [NSDate timeIntervalSinceReferenceDate] - _lastMetadataTimestamp;
            progress += static_cast<uint32_t>(delta * 1000.0);
            if (progress > bridge.currentDurationMs) progress = bridge.currentDurationMs;
        }
        _progressSlider.value = (float)progress / (float)bridge.currentDurationMs;
        _currentTimeLabel.text = [self formatTimeMs:progress];
        _totalTimeLabel.text = [self formatTimeMs:bridge.currentDurationMs];
    }
}

- (void)updateStatusDisplay {
    SendspinBridge *bridge = [SendspinBridge sharedInstance];
    SendspinConnectionState state = bridge.connectionState;
    switch (state) {
        case SendspinConnectionStateSynchronized:
            _statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.3 alpha:1.0];
            _statusLabel.text = [NSString stringWithFormat:@"Sync: %@", bridge.connectedServerName ?: @"Server"];
            break;
        case SendspinConnectionStateConnected:
            _statusDot.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.3 alpha:1.0];
            _statusLabel.text = [NSString stringWithFormat:@"Connected: %@", bridge.connectedServerName ?: @"Server"];
            break;
        case SendspinConnectionStateListening:
            _statusDot.backgroundColor = [UIColor colorWithRed:0.3 green:0.75 blue:0.95 alpha:1.0];
            _statusLabel.text = [NSString stringWithFormat:@"Port %u (mDNS Active)", bridge.listeningPort];
            break;
        case SendspinConnectionStateConnecting:
            _statusDot.backgroundColor = [UIColor colorWithRed:0.95 green:0.75 blue:0.2 alpha:1.0];
            _statusLabel.text = @"Connecting...";
            break;
        case SendspinConnectionStateDisconnected:
        default:
            _statusDot.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0];
            _statusLabel.text = @"Disconnected";
            break;
    }
}

- (void)updateNowPlayingDisplay {
    SendspinBridge *bridge = [SendspinBridge sharedInstance];
    _titleLabel.text = bridge.currentTitle.length > 0 ? bridge.currentTitle : @"Sendspin Player";
    
    if (bridge.currentAlbum.length > 0 && bridge.currentArtist.length > 0) {
        _artistAlbumLabel.text = [NSString stringWithFormat:@"%@ — %@", bridge.currentArtist, bridge.currentAlbum];
    } else if (bridge.currentArtist.length > 0) {
        _artistAlbumLabel.text = bridge.currentArtist;
    } else {
        _artistAlbumLabel.text = @"Ready to Stream";
    }
    
    if (bridge.currentArtwork) {
        _coverImageView.image = bridge.currentArtwork;
    }
    
    _baseProgressMs = bridge.currentProgressMs;
    _lastMetadataTimestamp = [NSDate timeIntervalSinceReferenceDate];

    if (!_isUserScrubbing && bridge.currentDurationMs > 0) {
        _progressSlider.value = (float)bridge.currentProgressMs / (float)bridge.currentDurationMs;
        _currentTimeLabel.text = [self formatTimeMs:bridge.currentProgressMs];
        _totalTimeLabel.text = [self formatTimeMs:bridge.currentDurationMs];
    }
    
    if (bridge.playbackState == SendspinPlaybackStatePlaying) {
        [_playPauseButton setImage:[self generatePauseIconInColor:[UIColor blackColor] size:CGSizeMake(22, 22)] forState:UIControlStateNormal];
    } else {
        [_playPauseButton setImage:[self generatePlayIconInColor:[UIColor blackColor] size:CGSizeMake(22, 22)] forState:UIControlStateNormal];
    }
}

- (void)updateDelayDisplay {
    int32_t delayMs = [AudioEngine sharedInstance].pioneerDelayMs;
    _delayLabel.text = [NSString stringWithFormat:@"Sync: %+d ms", (int)delayMs];
}

#pragma mark - Actions

- (void)onPlayPausePressed {
    [[SendspinBridge sharedInstance] togglePlayPause];
}

- (void)onPrevPressed {
    [[SendspinBridge sharedInstance] previousTrack];
}

- (void)onNextPressed {
    [[SendspinBridge sharedInstance] nextTrack];
}

- (void)onVolumeChanged:(UISlider *)slider {
    [[SendspinBridge sharedInstance] setVolume:slider.value];
}

- (void)onProgressSliderChanged:(UISlider *)slider {
    _isUserScrubbing = YES;
    uint32_t dur = [SendspinBridge sharedInstance].currentDurationMs;
    uint32_t targetMs = static_cast<uint32_t>(slider.value * dur);
    _currentTimeLabel.text = [self formatTimeMs:targetMs];
}

- (void)onProgressSliderTouchUp:(UISlider *)slider {
    _isUserScrubbing = NO;
    uint32_t dur = [SendspinBridge sharedInstance].currentDurationMs;
    uint32_t targetMs = static_cast<uint32_t>(slider.value * dur);
    _baseProgressMs = targetMs;
    _lastMetadataTimestamp = [NSDate timeIntervalSinceReferenceDate];
    [[SendspinBridge sharedInstance] seekToMs:targetMs];
}

- (void)onDelayMinus10 {
    [[SendspinBridge sharedInstance] adjustSyncDelayMs:-10];
    [self updateDelayDisplay];
}

- (void)onDelayMinus1 {
    [[SendspinBridge sharedInstance] adjustSyncDelayMs:-1];
    [self updateDelayDisplay];
}

- (void)onDelayPlus1 {
    [[SendspinBridge sharedInstance] adjustSyncDelayMs:+1];
    [self updateDelayDisplay];
}

- (void)onDelayPlus10 {
    [[SendspinBridge sharedInstance] adjustSyncDelayMs:+10];
    [self updateDelayDisplay];
}

- (void)onDelayReset {
    [AudioEngine sharedInstance].pioneerDelayMs = 0;
    [self updateDelayDisplay];
}

- (void)showServerDialog {
    SettingsViewController *settingsVC = [[SettingsViewController alloc] init];
    settingsVC.delegate = self;
    [self presentViewController:settingsVC animated:YES completion:nil];
}

- (void)settingsDidRequestDismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)promptConnectChoiceForServer:(NSDictionary *)server {
    NSString *name = server[@"name"] ?: @"Music Assistant";
    NSString *host = server[@"host"];
    uint16_t port = [server[@"port"] unsignedShortValue];

    if (NSClassFromString(@"UIAlertController")) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Connect to %@", name]
                                                                       message:[NSString stringWithFormat:@"Address: %@:%u\nWould you like to save this server as your default?", host, port]
                                                                preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Connect & Remember" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:name remember:YES];
        }];
        [alert addAction:saveAction];

        UIAlertAction *onceAction = [UIAlertAction actionWithTitle:@"Connect Once" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:name remember:NO];
        }];
        [alert addAction:onceAction];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:cancelAction];

        [self presentViewController:alert animated:YES completion:nil];
    } else {
        // Fallback for iOS 3 - 7
        [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:name remember:YES];
    }
}

- (void)showManualConnectAlert {
    if (NSClassFromString(@"UIAlertController")) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Manual Server"
                                                                       message:@"Enter Sendspin Server / Music Assistant IP and Port:"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Server IP (e.g. 192.168.1.152)";
            textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        }];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Port (default: 8927 / 8928)";
            textField.text = @"8927";
            textField.keyboardType = UIKeyboardTypeNumberPad;
        }];
        
        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Connect & Remember" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *host = alert.textFields[0].text;
            uint16_t port = [alert.textFields[1].text intValue];
            if (port == 0) port = 8927;
            
            [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:nil remember:YES];
        }];
        [alert addAction:saveAction];

        UIAlertAction *onceAction = [UIAlertAction actionWithTitle:@"Connect Once" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *host = alert.textFields[0].text;
            uint16_t port = [alert.textFields[1].text intValue];
            if (port == 0) port = 8927;
            
            [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:nil remember:NO];
        }];
        [alert addAction:onceAction];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:cancelAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)showPlayerNameAlert {
    if (NSClassFromString(@"UIAlertController")) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Player Name"
                                                                       message:@"Set friendly name advertised via Bonjour to Music Assistant:"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"Player Name";
            textField.text = [SendspinBridge sharedInstance].playerName;
        }];
        
        UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save & Restart" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *newName = alert.textFields[0].text;
            if (newName && newName.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:newName forKey:@"SendspinPlayerName"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [[SendspinBridge sharedInstance] startServiceWithName:newName port:8928];
            }
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:saveAction];
        [alert addAction:cancelAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - SendspinBridgeDelegate

- (void)sendspinConnectionStateChanged:(SendspinConnectionState)state message:(NSString *)msg {
    [self updateStatusDisplay];
}

- (void)sendspinPlaybackStateChanged:(SendspinPlaybackState)playbackState {
    [self updateNowPlayingDisplay];
}

- (void)sendspinMetadataUpdatedTitle:(NSString *)title 
                              artist:(NSString *)artist 
                               album:(NSString *)album 
                               genre:(NSString *)genre
                            trackNum:(uint16_t)trackNum
                          durationMs:(uint32_t)durationMs 
                          progressMs:(uint32_t)progressMs {
    _baseProgressMs = progressMs;
    _lastMetadataTimestamp = [NSDate timeIntervalSinceReferenceDate];
    [self updateNowPlayingDisplay];
}

- (void)sendspinArtworkUpdated:(UIImage *)image {
    [UIView transitionWithView:_coverImageView
                      duration:0.3
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self->_coverImageView.image = image ?: [self generatePlaceholderArtwork];
    } completion:nil];
}

- (void)sendspinVolumeUpdated:(float)volume muted:(BOOL)muted {
    _volumeSlider.value = volume;
}

- (void)sendspinDiscoveredServersUpdated:(NSArray<NSDictionary *> *)servers {
    _discoveredServers = servers;
}

- (void)sendspinPromptConnectToServer:(NSDictionary *)server {
    [self promptConnectChoiceForServer:server];
}

#pragma mark - AudioEngineDelegate

- (void)audioEngineRouteChanged:(NSString *)newRoute {
    NSLog(@"[ViewController] Audio route: %@", newRoute);
}

@end
