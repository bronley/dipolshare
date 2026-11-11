#import <Foundation/Foundation.h>
#import "LocalSendRadarLayout.h"
#import "LocalSendPhotoGridLayout.h"
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
    Check(LocalSendPhotoColumnsForWidth(320) == 4, @"Phone keeps four photo columns");
    Check(LocalSendPhotoColumnsForWidth(768) == 5, @"Portrait iPad uses five larger photo columns");
    Check(LocalSendPhotoColumnsForWidth(1024) == 7, @"Landscape iPad uses seven larger photo columns");
    CGFloat galleryWidths[] = {320, 468, 724, 768, 1024};
    for (NSUInteger i = 0; i < 5; i++) {
        CGFloat width = galleryWidths[i];
        NSUInteger columns = LocalSendPhotoColumnsForWidth(width);
        CGFloat tile = LocalSendPhotoTileSize(width, columns);
        CGFloat used = columns * tile + (columns - 1) * LocalSendPhotoGridSpacing(width);
        CGFloat available = width - 2 * LocalSendPhotoGridMargin(width);
        if (width >= 468) Check(tile >= 110, @"iPad gallery uses larger thumbnails");
        Check(tile >= 44, @"Photo tiles remain usable touch targets");
        Check(used <= available && used > available - columns, @"Photo grid fills the pane without clipping");
    }
    CGRect photoSlot = CGRectMake(28, 14, 120, 120);
    CGSize photoSizes[] = {CGSizeMake(1600, 900), CGSizeMake(900, 1600), CGSizeMake(1000, 1000)};
    for (NSUInteger i = 0; i < 3; i++) {
        CGRect frame = LocalSendPhotoFrameInSlot(photoSlot, photoSizes[i], 6);
        Check(CGRectContainsRect(photoSlot, frame), @"White photo frame stays within its grid slot");
        Check(fabs(CGRectGetMidX(frame) - CGRectGetMidX(photoSlot)) < 0.01 &&
              fabs(CGRectGetMidY(frame) - CGRectGetMidY(photoSlot)) < 0.01,
              @"Portrait and landscape photos stay centered");
        Check(fabs((frame.size.width - 12) / (frame.size.height - 12) -
                   photoSizes[i].width / photoSizes[i].height) < 0.01,
              @"Framed photos preserve their original aspect ratio");
    }
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

    // Real discovery-pane sizes after subtracting the iPad sidebar and bars.
    CGRect tabletLandscape = CGRectMake(0, 0, 724, 704);
    CGRect tabletPortrait = CGRectMake(0, 0, 468, 960);
    CGFloat tabletRadarY = [LocalSendRadarLayout radarCenterYInBounds:tabletLandscape];
    CGRect tabletText = CGRectMake(12, tabletRadarY + 101, 700, 74);
    NSArray *tabletReserved = [NSArray arrayWithObject:
        [NSValue valueWithBytes:&tabletText objCType:@encode(CGRect)]];
    NSDictionary *landscape = [LocalSendRadarLayout placementsForDevices:manyDevices
        inBounds:tabletLandscape previousPlacements:nil reservedFrames:tabletReserved];
    for (NSDictionary *placement in [landscape allValues]) {
        Check(!CGRectIntersectsRect([LocalSendRadarLayout frameForPlacement:placement], tabletText),
              @"iPad devices avoid the enlarged status and hint");
    }
    Check([landscape count] > 0, @"iPad landscape shows nearby devices");
    CheckLayout(manyDevices, tabletLandscape, landscape);
    NSDictionary *portrait = [LocalSendRadarLayout placementsForDevices:manyDevices
        inBounds:tabletPortrait previousPlacements:landscape reservedFrames:[NSArray array]];
    Check([portrait count] > 0, @"iPad rotation retains nearby devices");
    CheckLayout(manyDevices, tabletPortrait, portrait);

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
