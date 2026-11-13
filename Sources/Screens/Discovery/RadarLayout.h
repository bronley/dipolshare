#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface RadarLayout : NSObject

+ (NSString *)identifierForDevice:(NSDictionary *)device;
+ (CGFloat)radarCenterYInBounds:(CGRect)bounds;
+ (CGFloat)tabletRadarCenterYInBounds:(CGRect)bounds;
+ (CGRect)frameForPlacement:(NSDictionary *)placement;
+ (NSDictionary *)placementsForDevices:(NSArray *)devices
                              inBounds:(CGRect)bounds
                    previousPlacements:(NSDictionary *)previousPlacements
                        reservedFrames:(NSArray *)reservedFrames;

@end
