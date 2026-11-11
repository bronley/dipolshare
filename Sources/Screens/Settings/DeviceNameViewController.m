#import "DeviceNameViewController.h"
#import "Discovery.h"

@interface DeviceNameViewController ()
- (void)saveName;
@end

@implementation DeviceNameViewController

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
    _nameField.text = [Discovery deviceName];
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
    if (![Discovery setDeviceName:_nameField.text]) {
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
