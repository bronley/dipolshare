#import <UIKit/UIKit.h>

@class LocalSendDeviceListViewController;

@protocol LocalSendDeviceListDelegate <NSObject>
- (void)deviceListViewController:(LocalSendDeviceListViewController *)controller
                 didChooseDevice:(NSDictionary *)device;
@end

@interface LocalSendDeviceListViewController : UITableViewController {
    NSArray *_devices;
    id<LocalSendDeviceListDelegate> _delegate;
}

- (id)initWithDevices:(NSArray *)devices delegate:(id<LocalSendDeviceListDelegate>)delegate;

@end
