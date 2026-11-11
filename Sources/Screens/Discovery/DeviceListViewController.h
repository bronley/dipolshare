#import <UIKit/UIKit.h>

@class DeviceListViewController;

@protocol DeviceListDelegate <NSObject>
- (void)deviceListViewController:(DeviceListViewController *)controller
                 didChooseDevice:(NSDictionary *)device;
@end

@interface DeviceListViewController : UITableViewController {
    NSArray *_devices;
    id<DeviceListDelegate> _delegate;
}

- (id)initWithDevices:(NSArray *)devices delegate:(id<DeviceListDelegate>)delegate;

@end
