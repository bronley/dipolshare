#import <Foundation/Foundation.h>
#import "LocalSendRadarLayout.h"
#import <math.h>

static NSUInteger checks = 0;
static NSUInteger failures = 0;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        failures++;
    }
    printf("%s %s\n", condition ? "PASS" : "FAIL", [message UTF8String]);
}

static NSDictionary *Device(NSUInteger number) {
    return [NSDictionary
        dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Device %lu", (unsigned long)number],
                                     @"alias",
                                     [NSString stringWithFormat:@"fingerprint-%lu", (unsigned long)number],
                                     @"fingerprint", nil];
}

static void CheckLayout(NSArray *devices, CGRect bounds, NSDictionary *placements) {
    CGFloat radarY = [LocalSendRadarLayout radarCenterYInBounds:bounds];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSDictionary *device in devices) {
        NSDictionary *placement = [placements objectForKey:[LocalSendRadarLayout identifierForDevice:device]];
        if (placement == nil) {
            continue;
        }
        CGFloat scale = [[placement objectForKey:@"scale"] floatValue];
        Check(scale >= 0.6f && scale <= 1.0f, @"Blob size stays within the requested range");
        CGRect frame = [LocalSendRadarLayout frameForPlacement:placement];
        CGRect content = CGRectInset(bounds, 1.0f, 2.0f);
        Check(CGRectContainsRect(content, frame), @"Blob and name stay inside the radar screen");
        CGFloat distanceX = [[placement objectForKey:@"centerX"] floatValue] - CGRectGetMidX(bounds);
        CGFloat distanceY = [[placement objectForKey:@"centerY"] floatValue] - radarY;
        CGFloat clearance = 71.0f + 63.0f * scale / 2.0f + 5.0f;
        Check(distanceX * distanceX + distanceY * distanceY >= clearance * clearance,
              @"Blob stays clear of the radar face");
        for (NSValue *previous in frames) {
            CGRect previousFrame;
            [previous getValue:&previousFrame];
            Check(!CGRectIntersectsRect(frame, previousFrame), @"Device blobs and names do not overlap");
        }
        [frames addObject:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)]];
    }
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    CGRect shortScreen = CGRectMake(0.0f, 0.0f, 320.0f, 387.0f);
    CGRect tallScreen = CGRectMake(0.0f, 0.0f, 320.0f, 475.0f);
    NSArray *firstTwo = [NSArray arrayWithObjects:Device(1), Device(2), nil];
    NSDictionary *initial = [LocalSendRadarLayout placementsForDevices:firstTwo
                                                              inBounds:shortScreen
                                                    previousPlacements:nil
                                                        reservedFrames:[NSArray array]];
    Check([initial count] == 2, @"Two devices appear around the radar");
    CheckLayout(firstTwo, shortScreen, initial);

    NSMutableArray *manyDevices = [NSMutableArray array];
    for (NSUInteger index = 0; index < 30; index++) {
        [manyDevices addObject:Device(index)];
    }
    NSDictionary *crowded = [LocalSendRadarLayout placementsForDevices:manyDevices
                                                              inBounds:shortScreen
                                                    previousPlacements:initial
                                                        reservedFrames:[NSArray array]];
    Check([[crowded objectForKey:[LocalSendRadarLayout identifierForDevice:Device(1)]]
              isEqual:[initial objectForKey:[LocalSendRadarLayout identifierForDevice:Device(1)]]],
          @"Existing device keeps its position and size when more appear");
    Check([crowded count] < [manyDevices count], @"Crowded screen reports overflow for the device list");
    CheckLayout(manyDevices, shortScreen, crowded);

    NSDictionary *tall = [LocalSendRadarLayout placementsForDevices:manyDevices
                                                           inBounds:tallScreen
                                                 previousPlacements:nil
                                                     reservedFrames:[NSArray array]];
    CheckLayout(manyDevices, tallScreen, tall);

    NSDictionary *firstPlacement =
        [initial objectForKey:[LocalSendRadarLayout identifierForDevice:Device(1)]];
    CGRect reserved = [LocalSendRadarLayout frameForPlacement:firstPlacement];
    NSArray *reservedFrames = [NSArray arrayWithObject:[NSValue valueWithBytes:&reserved
                                                                      objCType:@encode(CGRect)]];
    NSDictionary *whileDisappearing =
        [LocalSendRadarLayout placementsForDevices:[NSArray arrayWithObject:Device(20)]
                                          inBounds:shortScreen
                                previousPlacements:nil
                                    reservedFrames:reservedFrames];
    NSDictionary *newPlacement =
        [whileDisappearing objectForKey:[LocalSendRadarLayout identifierForDevice:Device(20)]];
    Check(newPlacement != nil &&
              !CGRectIntersectsRect([LocalSendRadarLayout frameForPlacement:newPlacement], reserved),
          @"New blob avoids one that is still disappearing");

    printf("%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
    [pool drain];
    return failures == 0 ? 0 : 1;
}
