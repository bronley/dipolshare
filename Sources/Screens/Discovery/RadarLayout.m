#import "RadarLayout.h"
#import <math.h>
#import <stdint.h>

static const CGFloat BlobLabelWidth = 88.0f;
static const CGFloat BlobImageWidth = 63.0f;
static const CGFloat BlobLabelHeight = 29.0f;

static uint32_t DeviceHash(NSString *identifier) {
    const unsigned char *character = (const unsigned char *)[identifier UTF8String];
    uint32_t result = 2166136261U;
    while (character != NULL && *character != 0) {
        result = (result ^ *character) * 16777619U;
        character++;
    }
    return result;
}

static CGFloat BlobScale(NSString *identifier) {
    return 0.6f + (CGFloat)(DeviceHash(identifier) % 401U) / 1000.0f;
}

static NSDictionary *Placement(CGFloat centerX, CGFloat centerY, CGFloat scale,
                                        NSUInteger colorIndex) {
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithFloat:centerX], @"centerX",
                                                      [NSNumber numberWithFloat:centerY], @"centerY",
                                                      [NSNumber numberWithFloat:scale], @"scale",
                                                      [NSNumber numberWithUnsignedInteger:colorIndex],
                                                      @"colorIndex", nil];
}

static BOOL PlacementFits(NSDictionary *placement, CGRect bounds, CGFloat radarCenterY,
                                   NSArray *occupiedFrames) {
    CGRect frame = [RadarLayout frameForPlacement:placement];
    CGRect content = CGRectInset(bounds, 1.0f, 2.0f);
    if (!CGRectContainsRect(content, frame)) {
        return NO;
    }

    CGFloat centerX = [[placement objectForKey:@"centerX"] floatValue];
    CGFloat centerY = [[placement objectForKey:@"centerY"] floatValue];
    CGFloat imageRadius = BlobImageWidth * [[placement objectForKey:@"scale"] floatValue] / 2.0f;
    CGFloat distanceX = centerX - CGRectGetMidX(bounds);
    CGFloat distanceY = centerY - radarCenterY;
    CGFloat minimumDistance = 71.0f + imageRadius + 5.0f;
    if (distanceX * distanceX + distanceY * distanceY < minimumDistance * minimumDistance) {
        return NO;
    }

    CGRect statusArea = CGRectMake(CGRectGetMidX(bounds) - 80.0f, radarCenterY + 79.0f, 160.0f, 29.0f);
    CGRect imageFrame =
        CGRectMake(centerX - imageRadius, centerY - imageRadius, imageRadius * 2.0f, imageRadius * 2.0f);
    CGRect labelFrame = CGRectMake(centerX - BlobLabelWidth / 2.0f, centerY + imageRadius + 3.0f,
                                   BlobLabelWidth, BlobLabelHeight);
    if (CGRectIntersectsRect(statusArea, imageFrame) || CGRectIntersectsRect(statusArea, labelFrame)) {
        return NO;
    }
    for (NSValue *occupied in occupiedFrames) {
        CGRect occupiedFrame;
        [occupied getValue:&occupiedFrame];
        if (CGRectIntersectsRect(CGRectInset(frame, -2.0f, -2.0f), occupiedFrame)) {
            return NO;
        }
    }
    return YES;
}

@implementation RadarLayout

+ (NSString *)identifierForDevice:(NSDictionary *)device {
    NSString *fingerprint = [device objectForKey:@"fingerprint"];
    if ([fingerprint isKindOfClass:[NSString class]] && [fingerprint length] > 0) {
        return fingerprint;
    }
    return
        [NSString stringWithFormat:@"%@:%@", [device objectForKey:@"address"], [device objectForKey:@"port"]];
}

+ (CGFloat)radarCenterYInBounds:(CGRect)bounds {
    if (CGRectGetWidth(bounds) >= 468.0f) {
        return [self tabletRadarCenterYInBounds:bounds];
    }
    return CGRectGetMidY(bounds) + 2.0f;
}

+ (CGFloat)tabletRadarCenterYInBounds:(CGRect)bounds {
    return CGRectGetMinY(bounds) + CGRectGetHeight(bounds) * (266.0f / 704.0f);
}

+ (CGRect)frameForPlacement:(NSDictionary *)placement {
    CGFloat centerX = [[placement objectForKey:@"centerX"] floatValue];
    CGFloat centerY = [[placement objectForKey:@"centerY"] floatValue];
    CGFloat imageWidth = BlobImageWidth * [[placement objectForKey:@"scale"] floatValue];
    return CGRectMake(centerX - BlobLabelWidth / 2.0f, centerY - imageWidth / 2.0f,
                      BlobLabelWidth, imageWidth + 3.0f + BlobLabelHeight);
}

+ (NSDictionary *)placementsForDevices:(NSArray *)devices
                              inBounds:(CGRect)bounds
                    previousPlacements:(NSDictionary *)previousPlacements
                        reservedFrames:(NSArray *)reservedFrames {
    CGFloat radarCenterX = CGRectGetMidX(bounds);
    CGFloat radarCenterY = [self radarCenterYInBounds:bounds];
    NSMutableDictionary *placements = [NSMutableDictionary dictionary];
    NSMutableArray *occupiedFrames = [NSMutableArray arrayWithArray:reservedFrames];

    for (NSDictionary *device in devices) {
        NSString *identifier = [self identifierForDevice:device];
        NSDictionary *previous = [previousPlacements objectForKey:identifier];
        if (previous != nil && PlacementFits(previous, bounds, radarCenterY, occupiedFrames)) {
            [placements setObject:previous forKey:identifier];
            CGRect frame = [self frameForPlacement:previous];
            [occupiedFrames addObject:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)]];
        }
    }

    static const CGPoint preferredOffsets[] = {{-90.0f, -142.0f}, {98.0f, -93.0f},   {-108.0f, -40.0f},
                                               {108.0f, 5.0f},    {-116.0f, 112.0f}, {116.0f, 112.0f},
                                               {0.0f, -158.0f},   {0.0f, 141.0f}};
    for (NSDictionary *device in devices) {
        NSString *identifier = [self identifierForDevice:device];
        if ([placements objectForKey:identifier] != nil) {
            continue;
        }
        uint32_t hash = DeviceHash(identifier);
        CGFloat scale = BlobScale(identifier);
        NSUInteger colorIndex = (hash >> 12) % 4U;
        NSDictionary *chosen = nil;
        for (NSUInteger index = 0; index < sizeof(preferredOffsets) / sizeof(preferredOffsets[0]); index++) {
            CGPoint offset = preferredOffsets[index];
            NSDictionary *candidate =
                Placement(radarCenterX + offset.x, radarCenterY + offset.y, scale, colorIndex);
            if (PlacementFits(candidate, bounds, radarCenterY, occupiedFrames)) {
                chosen = candidate;
                break;
            }
        }
        for (NSUInteger ring = 0; chosen == nil && ring < 3; ring++) {
            CGFloat radius = 139.0f + 18.0f * ring;
            for (NSUInteger step = 0; step < 32; step++) {
                CGFloat angle = (CGFloat)step * (CGFloat)M_PI * 2.0f / 32.0f;
                NSDictionary *candidate =
                    Placement(radarCenterX + sinf(angle) * radius,
                                       radarCenterY - cosf(angle) * radius, scale, colorIndex);
                if (PlacementFits(candidate, bounds, radarCenterY, occupiedFrames)) {
                    chosen = candidate;
                    break;
                }
            }
        }
        if (chosen != nil) {
            [placements setObject:chosen forKey:identifier];
            CGRect frame = [self frameForPlacement:chosen];
            [occupiedFrames addObject:[NSValue valueWithBytes:&frame objCType:@encode(CGRect)]];
        }
    }
    return placements;
}

@end
