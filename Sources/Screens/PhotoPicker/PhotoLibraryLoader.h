#import <Foundation/Foundation.h>
#import <AssetsLibrary/AssetsLibrary.h>

@class PhotoLibraryLoader;

@protocol PhotoLibraryLoaderDelegate <NSObject>
// Both callbacks run on the main thread. Entries are PickerAsset instances.
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didLoadEntries:(NSArray *)entries;
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader
     didFinishWithEntries:(NSArray *)entries
                    error:(NSError *)error;
@end

@interface PhotoLibraryLoader : NSObject {
    ALAssetsLibrary *_library;
    NSOperationQueue *_photoLoadQueue;
    NSMutableArray *_loadingEntries;
    NSMutableSet *_loadedAssetURLs;
    id<PhotoLibraryLoaderDelegate> _delegate;
    BOOL _started;
    BOOL _cancelled;
    BOOL _completionEnqueued;
}
@property(nonatomic, assign) id<PhotoLibraryLoaderDelegate> delegate;
@property(nonatomic, readonly) ALAssetsLibrary *library;
- (id)initWithLibrary:(ALAssetsLibrary *)library;
// Set the delegate, start, and cancel on the main thread. Each loader runs once.
- (void)start;
// Detaches the delegate immediately and prevents further delivery.
- (void)cancel;
@end
