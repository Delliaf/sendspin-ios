//
//  SettingsViewController.mm
//  Sendspin Universal iOS Player
//

#import "SettingsViewController.h"

@interface SettingsViewController () {
    UITableView *_tableView;
    UIActivityIndicatorView *_scanSpinner;
    UITextField *_manualHostField;
    UITextField *_manualPortField;
    UITextField *_playerNameField;
    UISegmentedControl *_bufferLatencyControl;
    NSArray<NSDictionary *> *_discoveredServers;
    BOOL _isScanning;
}
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    
    CGFloat screenW = self.view.bounds.size.width;
    CGFloat screenH = self.view.bounds.size.height;
    
    // 1. Navigation / Header Bar
    UIView *navBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, 54)];
    navBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    navBar.layer.borderWidth = 0.5;
    navBar.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.8].CGColor;
    [self.view addSubview:navBar];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, screenW - 100, 30)];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.text = @"⚙ Settings & Servers";
    [navBar addSubview:titleLabel];
    
    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    doneButton.frame = CGRectMake(screenW - 74, 20, 62, 28);
    doneButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:1.0];
    doneButton.layer.cornerRadius = 5.0;
    [doneButton setTitle:@"Done" forState:UIControlStateNormal];
    doneButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [doneButton addTarget:self action:@selector(onDonePressed) forControlEvents:UIControlEventTouchUpInside];
    [navBar addSubview:doneButton];
    
    // 2. Settings Table View
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 54, screenW, screenH - 54) style:UITableViewStyleGrouped];
    _tableView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];
    
    _discoveredServers = [[SendspinBridge sharedInstance] discoveredServers];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onServersUpdated:)
                                                 name:@"SendspinDiscoveredServersUpdated"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)onDonePressed {
    [self.view endEditing:YES];
    if (self.delegate && [self.delegate respondsToSelector:@selector(settingsDidRequestDismiss)]) {
        [self.delegate settingsDidRequestDismiss];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)onServersUpdated:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_discoveredServers = [[SendspinBridge sharedInstance] discoveredServers];
        [self->_scanSpinner stopAnimating];
        self->_isScanning = NO;
        [self->_tableView reloadData];
    });
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: // Discovered Servers + Scan button
            return 1 + (_discoveredServers.count > 0 ? _discoveredServers.count : 1);
        case 1: // Manual Connection (Host, Port, Connect Button)
            return 3;
        case 2: // Audio Buffer & Latency Tuning
            return 1;
        case 3: // About / Version
            return 2;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Discovered Servers (mDNS / Bonjour)";
        case 1: return @"Manual Server Connection";
        case 2: return @"Audio Buffer & Stability Tuning";
        case 3: return @"About Sendspin";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *cellId = [NSString stringWithFormat:@"Cell_%ld_%ld", (long)indexPath.section, (long)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    
    CGFloat width = tableView.bounds.size.width;
    
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"🔄 Scan Local Network";
            cell.textLabel.textColor = [UIColor colorWithRed:0.35 green:0.75 blue:0.95 alpha:1.0];
            cell.detailTextLabel.text = _isScanning ? @"Scanning network for Music Assistant..." : @"Tap to search for active servers";
            cell.accessoryView = _scanSpinner;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            if (_discoveredServers.count == 0) {
                cell.textLabel.text = @"No servers discovered yet";
                cell.textLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
                cell.detailTextLabel.text = @"Check Wi-Fi or enter server IP below";
            } else {
                NSDictionary *srv = _discoveredServers[indexPath.row - 1];
                NSString *name = srv[@"name"] ?: @"Music Assistant";
                NSString *host = srv[@"host"] ?: @"";
                NSNumber *port = srv[@"port"] ?: @(8928);
                
                cell.textLabel.text = name;
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@:%@", host, port];
                
                UIButton *connBtn = [UIButton buttonWithType:UIButtonTypeCustom];
                connBtn.frame = CGRectMake(0, 0, 72, 28);
                connBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.65 blue:0.35 alpha:1.0];
                connBtn.layer.cornerRadius = 4.0;
                [connBtn setTitle:@"Connect" forState:UIControlStateNormal];
                connBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
                connBtn.tag = indexPath.row - 1;
                [connBtn addTarget:self action:@selector(onConnectDiscoveredServer:) forControlEvents:UIControlEventTouchUpInside];
                cell.accessoryView = connBtn;
            }
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Host / IP:";
            if (!_manualHostField) {
                _manualHostField = [[UITextField alloc] initWithFrame:CGRectMake(width - 190, 8, 175, 28)];
                _manualHostField.textColor = [UIColor whiteColor];
                _manualHostField.font = [UIFont systemFontOfSize:14];
                _manualHostField.textAlignment = NSTextAlignmentRight;
                _manualHostField.placeholder = @"192.168.1.163";
                _manualHostField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                _manualHostField.autocorrectionType = UITextAutocorrectionTypeNo;
                _manualHostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                
                NSString *savedHost = [[NSUserDefaults standardUserDefaults] stringForKey:@"SendspinLastHost"];
                if (savedHost.length > 0) {
                    _manualHostField.text = savedHost;
                }
            }
            cell.accessoryView = _manualHostField;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Port:";
            if (!_manualPortField) {
                _manualPortField = [[UITextField alloc] initWithFrame:CGRectMake(width - 110, 8, 95, 28)];
                _manualPortField.textColor = [UIColor whiteColor];
                _manualPortField.font = [UIFont systemFontOfSize:14];
                _manualPortField.textAlignment = NSTextAlignmentRight;
                _manualPortField.placeholder = @"8928";
                _manualPortField.keyboardType = UIKeyboardTypeNumberPad;
                
                NSString *savedPort = [[NSUserDefaults standardUserDefaults] stringForKey:@"SendspinLastPort"];
                _manualPortField.text = (savedPort.length > 0) ? savedPort : @"8928";
            }
            cell.accessoryView = _manualPortField;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"⚡ Connect to Manual Server";
            cell.textLabel.textColor = [UIColor colorWithRed:0.95 green:0.85 blue:0.45 alpha:1.0];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"Buffer Latency:";
        if (!_bufferLatencyControl) {
            _bufferLatencyControl = [[UISegmentedControl alloc] initWithItems:@[@"20ms", @"40ms", @"80ms"]];
            _bufferLatencyControl.frame = CGRectMake(0, 0, 160, 28);
            _bufferLatencyControl.tintColor = [UIColor colorWithRed:0.35 green:0.75 blue:0.95 alpha:1.0];
            _bufferLatencyControl.selectedSegmentIndex = 1; // 40ms balanced
            [_bufferLatencyControl addTarget:self action:@selector(onBufferLatencyChanged:) forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = _bufferLatencyControl;
        cell.detailTextLabel.text = @"Recommended: 40ms (Prevents crackling on iPhone 4s)";
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Application Version";
            cell.detailTextLabel.text = @"Sendspin v1.0.1 (Build 107)";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Audio Engine";
            cell.detailTextLabel.text = @"Lock-Free SPSC CoreAudio RemoteIO";
        }
    }
    
    return cell;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.view endEditing:YES];
    
    if (indexPath.section == 0 && indexPath.row == 0) {
        _isScanning = YES;
        if (!_scanSpinner) {
            _scanSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        }
        [_scanSpinner startAnimating];
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        [[SendspinBridge sharedInstance] rescanBonjourServers];
    } else if (indexPath.section == 1 && indexPath.row == 2) {
        [self onManualConnectPressed];
    }
}

- (void)onConnectDiscoveredServer:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= 0 && idx < _discoveredServers.count) {
        NSDictionary *srv = _discoveredServers[idx];
        NSString *host = srv[@"host"];
        uint16_t port = [srv[@"port"] unsignedShortValue];
        NSString *name = srv[@"name"] ?: @"Music Assistant";
        
        NSLog(@"[Settings] Connecting to discovered server: %@:%u", host, port);
        [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:name remember:YES];
        [self onDonePressed];
    }
}

- (void)onManualConnectPressed {
    NSString *host = [_manualHostField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *portStr = [_manualPortField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if (host.length == 0) {
        host = @"192.168.1.163";
    }
    uint16_t port = (portStr.length > 0) ? (uint16_t)[portStr intValue] : 8928;
    
    [[NSUserDefaults standardUserDefaults] setObject:host forKey:@"SendspinLastHost"];
    [[NSUserDefaults standardUserDefaults] setObject:portStr forKey:@"SendspinLastPort"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSLog(@"[Settings] Connecting to manual server: %@:%u", host, port);
    [[SendspinBridge sharedInstance] connectToRemoteServer:host port:port name:@"Manual Server" remember:YES];
    [self onDonePressed];
}

- (void)onBufferLatencyChanged:(UISegmentedControl *)sender {
    Float64 duration = 0.040; // 40ms default
    if (sender.selectedSegmentIndex == 0) duration = 0.020;
    else if (sender.selectedSegmentIndex == 2) duration = 0.080;
    
    if (NSClassFromString(@"AVAudioSession")) {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if ([session respondsToSelector:@selector(setPreferredIOBufferDuration:error:)]) {
            [session setPreferredIOBufferDuration:duration error:nil];
            NSLog(@"[AudioEngine] Set preferred buffer duration: %.3f s", duration);
        }
    }
}

@end
