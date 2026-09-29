#import "LocalSendSettingsViewController.h"
#import "LocalSendDiscovery.h"

static const NSInteger LocalSendRegenerateKeyAlertTag = 1001;
static const NSInteger LocalSendCreditLogoTag = 1002;
static const NSInteger LocalSendCreditCaptionTag = 1003;

@interface LocalSendDeviceNameViewController : UIViewController <UITextFieldDelegate> {
    UITextField *_nameField;
}
- (void)saveName;
@end

@implementation LocalSendDeviceNameViewController

- (void)dealloc {
    [_nameField release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Device name";
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
        target:self action:@selector(saveName)] autorelease];

    _nameField = [[UITextField alloc] initWithFrame:CGRectMake(20.0f, 24.0f,
                                                self.view.bounds.size.width - 40.0f, 36.0f)];
    _nameField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _nameField.borderStyle = UITextBorderStyleRoundedRect;
    _nameField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    _nameField.returnKeyType = UIReturnKeyDone;
    _nameField.delegate = self;
    _nameField.text = [LocalSendDiscovery deviceName];
    [self.view addSubview:_nameField];

    UILabel *hint = [[[UILabel alloc] initWithFrame:CGRectMake(20.0f, 68.0f,
                                              self.view.bounds.size.width - 40.0f, 54.0f)] autorelease];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    hint.backgroundColor = [UIColor clearColor];
    hint.font = [UIFont systemFontOfSize:13.0f];
    hint.textColor = [UIColor grayColor];
    hint.numberOfLines = 2;
    hint.text = @"Visible to other devices on your local network. Clear the name to use this iPhone's device name.";
    [self.view addSubview:hint];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_nameField becomeFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveName];
    return YES;
}

- (void)saveName {
    if (![LocalSendDiscovery setDeviceName:_nameField.text]) {
        UIAlertView *error = [[[UIAlertView alloc] initWithTitle:@"Invalid name"
                                                        message:@"Use up to 64 characters without line breaks."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil] autorelease];
        [error show];
        return;
    }
    [_nameField resignFirstResponder];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface LocalSendSettingsViewController ()
- (void)layoutCreditFooter;
@end

@implementation LocalSendSettingsViewController

- (id)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";

    UIView *creditFooter = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f,
                                      self.tableView.bounds.size.width, 128.0f)] autorelease];
    creditFooter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    creditFooter.backgroundColor = [UIColor clearColor];

    UIImageView *logo = [[[UIImageView alloc] initWithImage:
        [UIImage imageNamed:@"LoveIsInTheTech"]] autorelease];
    logo.tag = LocalSendCreditLogoTag;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.isAccessibilityElement = YES;
    logo.accessibilityLabel = @"love is in the tech";
    [creditFooter addSubview:logo];

    UILabel *caption = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    caption.tag = LocalSendCreditCaptionTag;
    caption.backgroundColor = [UIColor clearColor];
    caption.font = [UIFont systemFontOfSize:12.0f];
    caption.textColor = [UIColor grayColor];
    caption.textAlignment = UITextAlignmentCenter;
    caption.numberOfLines = 2;
    caption.text = @"Brought to you for free by loveisinthe.tech";
    [creditFooter addSubview:caption];
    self.tableView.tableFooterView = creditFooter;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityRegenerated:)
                                                 name:LocalSendDiscoveryIdentityDidRegenerateNotification
                                               object:[LocalSendDiscovery sharedDiscovery]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityLoaded:)
                                                 name:LocalSendDiscoverySetupDidChangeNotification
                                               object:[LocalSendDiscovery sharedDiscovery]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityLoaded:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:NO];
    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self layoutCreditFooter];
}

- (void)layoutCreditFooter {
    UIView *footer = self.tableView.tableFooterView;
    CGFloat footerHeight = footer.bounds.size.height;
    CGFloat contentWithoutFooter = self.tableView.contentSize.height - footerHeight;
    CGFloat requiredHeight = self.tableView.bounds.size.height - contentWithoutFooter;
    CGFloat newHeight = MAX(128.0f, requiredHeight);
    if (newHeight > footerHeight + 1.0f || newHeight < footerHeight - 1.0f) {
        footer.frame = CGRectMake(0.0f, 0.0f, self.tableView.bounds.size.width, newHeight);
        self.tableView.tableFooterView = footer;
    }

    CGFloat width = footer.bounds.size.width;
    UIImageView *logo = (UIImageView *)[footer viewWithTag:LocalSendCreditLogoTag];
    CGFloat logoWidth = MIN(234.0f, width - 32.0f);
    logo.frame = CGRectMake((width - logoWidth) / 2.0f, newHeight - 98.0f,
                            logoWidth, 33.0f);
    UILabel *caption = (UILabel *)[footer viewWithTag:LocalSendCreditCaptionTag];
    caption.frame = CGRectMake(12.0f, newHeight - 53.0f, width - 24.0f, 33.0f);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 1 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return @"This device";
    }
    return section == 1 ? @"Security" : @"About";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Visible to other devices on your local network. Clear the name to use this iPhone's device name.";
    }
    if (section != 1) {
        return nil;
    }
    NSString *setupError = [[LocalSendDiscovery sharedDiscovery] identitySetupError];
    if (setupError != nil) {
        return setupError;
    }
    LocalSendCertificateDateStatus status = [[LocalSendDiscovery sharedDiscovery] certificateDateStatus];
    if (status == LocalSendCertificateDateStatusClockIncorrect) {
        return @"Correct this device's date and time before regenerating the key.";
    }
    if (status == LocalSendCertificateDateStatusExpired ||
        status == LocalSendCertificateDateStatusNotYetValid) {
        return @"Check the device date and time, then regenerate the key.";
    }
    return @"A new certificate changes this device's identity. Other devices may need to discover it again.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                    reuseIdentifier:nil] autorelease];
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Name";
        cell.detailTextLabel.text = [LocalSendDiscovery deviceName];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            LocalSendCertificateDateStatus status = [[LocalSendDiscovery sharedDiscovery] certificateDateStatus];
            NSString *setupError = [[LocalSendDiscovery sharedDiscovery] identitySetupError];
            cell.textLabel.text = @"Certificate";
            if (setupError != nil) {
                cell.detailTextLabel.text = @"Setup failed";
            } else {
                switch (status) {
                    case LocalSendCertificateDateStatusValid: cell.detailTextLabel.text = @"Valid"; break;
                    case LocalSendCertificateDateStatusExpired: cell.detailTextLabel.text = @"Expired"; break;
                    case LocalSendCertificateDateStatusNotYetValid: cell.detailTextLabel.text = @"Not yet valid"; break;
                    case LocalSendCertificateDateStatusClockIncorrect: cell.detailTextLabel.text = @"Check clock"; break;
                    case LocalSendCertificateDateStatusInvalid: cell.detailTextLabel.text = @"Invalid"; break;
                    default: cell.detailTextLabel.text = @"Checking…"; break;
                }
            }
            if (setupError != nil || (status != LocalSendCertificateDateStatusValid &&
                status != LocalSendCertificateDateStatusUnavailable)) {
                cell.detailTextLabel.textColor = [UIColor redColor];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            BOOL busy = [[LocalSendDiscovery sharedDiscovery] isRegeneratingIdentity];
            cell.textLabel.text = busy ? @"Regenerating key…" : @"Regenerate device key";
            cell.textLabel.textColor = busy ? [UIColor grayColor] : [UIColor redColor];
            cell.selectionStyle = busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleBlue;
        }
    } else {
        cell.textLabel.text = @"Version";
        cell.detailTextLabel.text = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        LocalSendDeviceNameViewController *editor = [[LocalSendDeviceNameViewController alloc] init];
        [self.navigationController pushViewController:editor animated:YES];
        [editor release];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    if (indexPath.section == 1) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (indexPath.row == 0) {
            return;
        }
        if ([[LocalSendDiscovery sharedDiscovery] isRegeneratingIdentity]) {
            return;
        }
        NSString *date = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterMediumStyle
                                                         timeStyle:NSDateFormatterShortStyle];
        NSString *message = [NSString stringWithFormat:
            @"Device date: %@. Correct the clock first if this is wrong. A new key changes this device's identity and interrupts active transfers.", date];
        UIAlertView *confirmation = [[[UIAlertView alloc] initWithTitle:@"Regenerate device key?"
                                                               message:message
                                                              delegate:self
                                                     cancelButtonTitle:@"Cancel"
                                                     otherButtonTitles:@"Regenerate", nil] autorelease];
        confirmation.tag = LocalSendRegenerateKeyAlertTag;
        [confirmation show];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != LocalSendRegenerateKeyAlertTag || buttonIndex != 1) {
        return;
    }
    if (![[LocalSendDiscovery sharedDiscovery] regenerateIdentity]) {
        UIAlertView *busy = [[[UIAlertView alloc] initWithTitle:@"Please wait"
                                                        message:@"Device identity setup is already in progress."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil] autorelease];
        [busy show];
        return;
    }
    [self.tableView reloadData];
}

- (void)identityRegenerated:(NSNotification *)notification {
    [self.tableView reloadData];
    BOOL succeeded = [[[notification userInfo] objectForKey:@"success"] boolValue];
    NSString *message = succeeded
        ? @"The new key and certificate are active. Other devices may need to discover this device again."
        : [[notification userInfo] objectForKey:@"error"];
    UIAlertView *result = [[[UIAlertView alloc]
        initWithTitle:succeeded ? @"New key ready" : @"Could not regenerate key"
              message:message
             delegate:nil
    cancelButtonTitle:@"OK"
    otherButtonTitles:nil] autorelease];
    [result show];
}

- (void)identityLoaded:(NSNotification *)notification {
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

@end
