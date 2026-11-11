#import "SettingsViewController.h"
#import "DeviceNameViewController.h"
#import "DiscoveryStatusViewController.h"
#import "Discovery.h"
#import "Sounds.h"

typedef enum {
    SettingsSectionThisDevice,
    SettingsSectionSecurity,
    SettingsSectionAbout,
    SettingsSectionCount
} SettingsSection;

typedef enum {
    SettingsThisDeviceRowName,
    SettingsThisDeviceRowDiscoveryStatus,
    SettingsThisDeviceRowSoundEffects,
    SettingsThisDeviceRowCount
} SettingsThisDeviceRow;

typedef enum {
    SettingsSecurityRowCertificate,
    SettingsSecurityRowRegenerateKey,
    SettingsSecurityRowCount
} SettingsSecurityRow;

typedef enum {
    SettingsAboutRowVersion,
    SettingsAboutRowCount
} SettingsAboutRow;

static const NSInteger RegenerateKeyAlertTag = 1001;
static const NSInteger CreditLogoTag = 1002;
static const NSInteger CreditCaptionTag = 1003;

@interface SettingsViewController ()
- (void)configureThisDeviceCell:(UITableViewCell *)cell forRow:(NSInteger)row;
- (void)configureSoundEffectsCell:(UITableViewCell *)cell;
- (void)configureSecurityCell:(UITableViewCell *)cell forRow:(NSInteger)row;
- (void)configureCertificateCell:(UITableViewCell *)cell;
- (void)configureRegenerateKeyCell:(UITableViewCell *)cell;
- (void)configureAboutCell:(UITableViewCell *)cell forRow:(NSInteger)row;
- (void)handleThisDeviceRowSelection:(NSInteger)row;
- (void)handleSecurityRowSelection:(NSInteger)row;
- (void)handleAboutRowSelection:(NSInteger)row;
- (void)showRegenerateKeyConfirmation;
- (void)layoutCreditFooter;
- (void)soundEffectsChanged:(UISwitch *)sender;
@end

@implementation SettingsViewController

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
    logo.tag = CreditLogoTag;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.isAccessibilityElement = YES;
    logo.accessibilityLabel = @"love is in the tech";
    [creditFooter addSubview:logo];

    UILabel *caption = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    caption.tag = CreditCaptionTag;
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
                                                 name:DiscoveryIdentityDidRegenerateNotification
                                               object:[Discovery sharedDiscovery]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(identityLoaded:)
                                                 name:DiscoverySetupDidChangeNotification
                                               object:[Discovery sharedDiscovery]];
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
    UIImageView *logo = (UIImageView *)[footer viewWithTag:CreditLogoTag];
    CGFloat logoWidth = MIN(234.0f, width - 32.0f);
    logo.frame = CGRectMake((width - logoWidth) / 2.0f, newHeight - 98.0f,
                            logoWidth, 33.0f);
    UILabel *caption = (UILabel *)[footer viewWithTag:CreditCaptionTag];
    caption.frame = CGRectMake(12.0f, newHeight - 53.0f, width - 24.0f, 33.0f);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionThisDevice:
            return SettingsThisDeviceRowCount;
        case SettingsSectionSecurity:
            return SettingsSecurityRowCount;
        case SettingsSectionAbout:
            return SettingsAboutRowCount;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionThisDevice:
            return @"This device";
        case SettingsSectionSecurity:
            return @"Security";
        case SettingsSectionAbout:
            return @"About";
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionThisDevice:
            return @"Visible to other devices on your local network. Clear the name to use this iPhone's device name.";
        case SettingsSectionSecurity: {
            NSString *setupError = [[Discovery sharedDiscovery] identitySetupError];
            if (setupError != nil) {
                return setupError;
            }
            CertificateDateStatus status = [[Discovery sharedDiscovery] certificateDateStatus];
            if (status == CertificateDateStatusClockIncorrect) {
                return @"Correct this device's date and time before regenerating the key.";
            }
            if (status == CertificateDateStatusExpired ||
                status == CertificateDateStatusNotYetValid) {
                return @"Check the device date and time, then regenerate the key.";
            }
            return @"A new certificate changes this device's identity. Other devices may need to discover it again.";
        }
        case SettingsSectionAbout:
            return nil;
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                    reuseIdentifier:nil] autorelease];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    switch (indexPath.section) {
        case SettingsSectionThisDevice:
            [self configureThisDeviceCell:cell forRow:indexPath.row];
            break;
        case SettingsSectionSecurity:
            [self configureSecurityCell:cell forRow:indexPath.row];
            break;
        case SettingsSectionAbout:
            [self configureAboutCell:cell forRow:indexPath.row];
            break;
        default:
            break;
    }
    return cell;
}

- (void)configureThisDeviceCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    switch (row) {
        case SettingsThisDeviceRowName:
            cell.textLabel.text = @"Name";
            cell.detailTextLabel.text = [Discovery deviceName];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        case SettingsThisDeviceRowDiscoveryStatus:
            cell.textLabel.text = @"Discovery status";
            cell.detailTextLabel.text = @"View report";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        case SettingsThisDeviceRowSoundEffects:
            [self configureSoundEffectsCell:cell];
            break;
        default:
            break;
    }
}

- (void)configureSoundEffectsCell:(UITableViewCell *)cell {
    cell.textLabel.text = @"Sound effects";
    UISwitch *soundSwitch = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
    soundSwitch.on = [Sounds soundEffectsEnabled];
    soundSwitch.accessibilityLabel = @"Sound effects";
    [soundSwitch addTarget:self action:@selector(soundEffectsChanged:)
         forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = soundSwitch;
}

- (void)configureSecurityCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    switch (row) {
        case SettingsSecurityRowCertificate:
            [self configureCertificateCell:cell];
            break;
        case SettingsSecurityRowRegenerateKey:
            [self configureRegenerateKeyCell:cell];
            break;
        default:
            break;
    }
}

- (void)configureCertificateCell:(UITableViewCell *)cell {
    CertificateDateStatus status = [[Discovery sharedDiscovery] certificateDateStatus];
    NSString *setupError = [[Discovery sharedDiscovery] identitySetupError];
    cell.textLabel.text = @"Certificate";
    if (setupError != nil) {
        cell.detailTextLabel.text = @"Setup failed";
    } else {
        switch (status) {
            case CertificateDateStatusValid: cell.detailTextLabel.text = @"Valid"; break;
            case CertificateDateStatusExpired: cell.detailTextLabel.text = @"Expired"; break;
            case CertificateDateStatusNotYetValid: cell.detailTextLabel.text = @"Not yet valid"; break;
            case CertificateDateStatusClockIncorrect: cell.detailTextLabel.text = @"Check clock"; break;
            case CertificateDateStatusInvalid: cell.detailTextLabel.text = @"Invalid"; break;
            default: cell.detailTextLabel.text = @"Checking…"; break;
        }
    }
    if (setupError != nil || (status != CertificateDateStatusValid &&
        status != CertificateDateStatusUnavailable)) {
        cell.detailTextLabel.textColor = [UIColor redColor];
    }
}

- (void)configureRegenerateKeyCell:(UITableViewCell *)cell {
    BOOL busy = [[Discovery sharedDiscovery] isRegeneratingIdentity];
    cell.textLabel.text = busy ? @"Regenerating key…" : @"Regenerate device key";
    cell.textLabel.textColor = busy ? [UIColor grayColor] : [UIColor redColor];
    cell.selectionStyle = busy ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleBlue;
}

- (void)configureAboutCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    switch (row) {
        case SettingsAboutRowVersion:
            cell.textLabel.text = @"Version";
            cell.detailTextLabel.text = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
            break;
        default:
            break;
    }
}

- (void)soundEffectsChanged:(UISwitch *)sender {
    [Sounds setSoundEffectsEnabled:sender.on];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case SettingsSectionThisDevice:
            [self handleThisDeviceRowSelection:indexPath.row];
            return;
        case SettingsSectionSecurity:
            [self handleSecurityRowSelection:indexPath.row];
            return;
        case SettingsSectionAbout:
            [self handleAboutRowSelection:indexPath.row];
            return;
        default:
            return;
    }
}

- (void)handleThisDeviceRowSelection:(NSInteger)row {
    switch (row) {
        case SettingsThisDeviceRowName: {
            DeviceNameViewController *editor = [[DeviceNameViewController alloc] init];
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                editor.contentSizeForViewInPopover = self.contentSizeForViewInPopover;
            }
            [self.navigationController pushViewController:editor animated:YES];
            [editor release];
            return;
        }
        case SettingsThisDeviceRowDiscoveryStatus: {
            DiscoveryStatusViewController *report = [[DiscoveryStatusViewController alloc] init];
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
                report.contentSizeForViewInPopover = self.contentSizeForViewInPopover;
            }
            [self.navigationController pushViewController:report animated:YES];
            [report release];
            return;
        }
        case SettingsThisDeviceRowSoundEffects:
            return;
        default:
            return;
    }
}

- (void)handleSecurityRowSelection:(NSInteger)row {
    switch (row) {
        case SettingsSecurityRowCertificate:
            return;
        case SettingsSecurityRowRegenerateKey:
            [self showRegenerateKeyConfirmation];
            return;
        default:
            return;
    }
}

- (void)handleAboutRowSelection:(NSInteger)row {
    switch (row) {
        case SettingsAboutRowVersion:
            return;
        default:
            return;
    }
}

- (void)showRegenerateKeyConfirmation {
    if ([[Discovery sharedDiscovery] isRegeneratingIdentity]) {
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
    confirmation.tag = RegenerateKeyAlertTag;
    [confirmation show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != RegenerateKeyAlertTag || buttonIndex != 1) {
        return;
    }
    if (![[Discovery sharedDiscovery] regenerateIdentity]) {
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
