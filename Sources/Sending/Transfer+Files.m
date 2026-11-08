#import "Transfer+Private.h"
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <MobileCoreServices/UTType.h>
#else
#import <CoreServices/CoreServices.h>
#endif

static NSString *ContentTypeForPhotoName(NSString *fileName) {
    NSString *extension = [[fileName pathExtension] lowercaseString];
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"] ||
        [extension isEqualToString:@"jpe"]) {
        return @"image/jpeg";
    }
    if ([extension isEqualToString:@"png"]) {
        return @"image/png";
    }
    if ([extension isEqualToString:@"gif"]) {
        return @"image/gif";
    }
    if ([extension isEqualToString:@"tif"] || [extension isEqualToString:@"tiff"]) {
        return @"image/tiff";
    }
    if ([extension isEqualToString:@"bmp"]) {
        return @"image/bmp";
    }
    if ([extension isEqualToString:@"mov"] || [extension isEqualToString:@"qt"]) {
        return @"video/quicktime";
    }
    if ([extension isEqualToString:@"mp4"] || [extension isEqualToString:@"m4v"]) {
        return @"video/mp4";
    }
    if ([extension isEqualToString:@"3gp"] || [extension isEqualToString:@"3gpp"]) {
        return @"video/3gpp";
    }
    return @"application/octet-stream";
}

static NSString *RepresentationTag(ALAssetRepresentation *representation, CFStringRef tagClass) {
    NSString *type = [representation UTI];
    if ([type length] == 0) {
        return nil;
    }
    NSString *tag = [(NSString *)UTTypeCopyPreferredTagWithClass((CFStringRef)type, tagClass) autorelease];
    if ([tag length] > 0) {
        return tag;
    }
    NSString *extension = nil;
    if ([type isEqual:@"public.jpeg"]) extension = @"jpg";
    else if ([type isEqual:@"public.png"]) extension = @"png";
    else if ([type isEqual:@"com.compuserve.gif"]) extension = @"gif";
    else if ([type isEqual:@"public.tiff"]) extension = @"tif";
    else if ([type isEqual:@"com.microsoft.bmp"]) extension = @"bmp";
    else if ([type isEqual:@"com.apple.quicktime-movie"]) extension = @"mov";
    else if ([type isEqual:@"public.mpeg-4"]) extension = @"mp4";
    else if ([type isEqual:@"com.apple.m4v-video"]) extension = @"m4v";
    else if ([type isEqual:@"public.3gpp"]) extension = @"3gp";
    if (extension == nil) {
        return nil;
    }
    return CFEqual(tagClass, kUTTagClassFilenameExtension)
               ? extension : ContentTypeForPhotoName([@"asset" stringByAppendingPathExtension:extension]);
}

static NSString *FileNameForAsset(ALAsset *asset, ALAssetRepresentation *representation,
                                  NSString *identifier) {
    if ([representation respondsToSelector:@selector(filename)]) {
        return [[representation filename] lastPathComponent];
    }
    NSString *extension = RepresentationTag(representation, kUTTagClassFilenameExtension);
    NSString *prefix = [[asset valueForProperty:ALAssetPropertyType] isEqual:ALAssetTypeVideo]
                           ? @"Video" : @"Photo";
    NSString *name = [NSString stringWithFormat:@"%@-%@", prefix, identifier];
    return [extension length] > 0 ? [name stringByAppendingPathExtension:extension] : name;
}

@implementation Transfer (Files)

- (NSDictionary *)outgoingFileForPhoto:(ALAsset *)asset {
    ALAssetRepresentation *representation = [asset defaultRepresentation];
    long long byteCount = [representation size];
    NSString *fileIdentifier = [NewFileIdentifier() autorelease];
    NSString *fileName = FileNameForAsset(asset, representation, fileIdentifier);
    if (representation == nil || [fileName length] == 0 || byteCount <= 0 || [fileName hasPrefix:@"."] ||
        [fileName rangeOfString:@":"].location != NSNotFound ||
        [[fileName dataUsingEncoding:NSUTF8StringEncoding] length] > 240) {
        [self failWithMessage:@"Transfer failed: a selected photo or video has invalid name or data."];
        return nil;
    }
    NSString *contentType = RepresentationTag(representation, kUTTagClassMIMEType);
    if ([contentType length] == 0) {
        contentType = ContentTypeForPhotoName(fileName);
    }
    NSDictionary *file = [NSDictionary
        dictionaryWithObjectsAndKeys:fileIdentifier, @"id", fileName, @"fileName",
                                     [NSNumber numberWithLongLong:byteCount], @"size",
                                     contentType, @"fileType", asset, @"asset", nil];
    return file;
}

- (NSDictionary *)outgoingFileForClipboard {
    return [NSDictionary
        dictionaryWithObjectsAndKeys:_clipboardFileIdentifier, @"id", @"Clipboard.txt", @"fileName",
                                     [NSNumber numberWithUnsignedInteger:[_clipboardData length]], @"size",
                                     @"text/plain", @"fileType", _clipboardText, @"preview", _clipboardData,
                                     @"data", nil];
}

- (BOOL)prepareOutgoingFiles {
    NSMutableArray *files = [NSMutableArray array];
    if (_contactsFileName != nil) {
        NSDictionary *attributes = _contactsFilePath != nil
            ? [[NSFileManager defaultManager] attributesOfItemAtPath:_contactsFilePath error:NULL] : nil;
        unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
        if (size == 0 || ![[attributes objectForKey:NSFileType] isEqual:NSFileTypeRegular] ||
            ![[_contactsFileName lastPathComponent] isEqual:_contactsFileName] ||
            ![[_contactsFileName pathExtension] isEqual:@"vcf"]) {
            [self failWithMessage:@"Transfer failed: the contact backup is missing or invalid."];
            return NO;
        }
        NSString *identifier = [NewFileIdentifier() autorelease];
        [files addObject:[NSDictionary dictionaryWithObjectsAndKeys:identifier, @"id",
            _contactsFileName, @"fileName", [NSNumber numberWithUnsignedLongLong:size], @"size",
            @"text/vcard", @"fileType", nil]];
    }
    if ([_photoAssets count] > 100) {
        [self failWithMessage:@"Transfer failed: select at most 100 photos and videos."];
        return NO;
    }
    for (ALAsset *asset in _photoAssets) {
        NSDictionary *file = [self outgoingFileForPhoto:asset];
        if (file == nil) {
            return NO;
        }
        [files addObject:file];
    }
    if ([files count] == 0) {
        [files addObject:[self outgoingFileForClipboard]];
    }
    [_outgoingFiles release];
    _outgoingFiles = [files copy];
    return YES;
}
@end
