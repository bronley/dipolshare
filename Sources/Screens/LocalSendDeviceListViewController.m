#import "LocalSendDeviceListViewController.h"

@interface LocalSendDeviceListViewController ()
- (void)close:(id)sender;
@end

@implementation LocalSendDeviceListViewController

- (id)initWithDevices:(NSArray *)devices delegate:(id<LocalSendDeviceListDelegate>)delegate {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        _devices = [devices copy];
        _delegate = delegate;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Nearby devices";
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                          target:self
                                                                          action:@selector(close:)];
    self.navigationItem.rightBarButtonItem = done;
    [done release];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_devices count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"NearbyDevice";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:identifier] autorelease];
    }
    NSDictionary *device = [_devices objectAtIndex:indexPath.row];
    cell.textLabel.text = [device objectForKey:@"alias"];
    cell.detailTextLabel.text = [device objectForKey:@"model"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *device = [_devices objectAtIndex:indexPath.row];
    [_delegate deviceListViewController:self didChooseDevice:device];
}

- (void)close:(id)sender {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)dealloc {
    [_devices release];
    [super dealloc];
}

@end
