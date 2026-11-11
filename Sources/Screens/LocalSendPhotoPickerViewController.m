#import "LocalSendPhotoPickerViewController.h"

static const NSUInteger LocalSendMaximumSelectedPhotos = 100;
static const NSUInteger LocalSendPhotoLoadingBatchSize = 32;

@interface LocalSendPickerAsset : NSObject {
@public
    ALAsset *asset;
    NSDate *date;
    BOOL isVideo;
}
- (id)initWithAsset:(ALAsset *)photoAsset;
@end

@implementation LocalSendPickerAsset
- (id)initWithAsset:(ALAsset *)photoAsset {
    self = [super init];
    if (self) {
        asset = [photoAsset retain];
        id creationDate = [photoAsset valueForProperty:ALAssetPropertyDate];
        date = [([creationDate isKindOfClass:[NSDate class]] ? creationDate : [NSDate distantPast]) retain];
        isVideo = [[photoAsset valueForProperty:ALAssetPropertyType] isEqualToString:ALAssetTypeVideo];
    }
    return self;
}
- (void)dealloc {
    [asset release];
    [date release];
    [super dealloc];
}
@end

@interface LocalSendPhotoLoadTarget : NSObject {
    LocalSendPhotoPickerViewController *_picker;
}
- (id)initWithPicker:(LocalSendPhotoPickerViewController *)picker;
- (LocalSendPhotoPickerViewController *)picker;
- (void)enumeratePhotoGroup:(ALAssetsGroup *)group;
- (void)finishPhotoEnumeration:(NSError *)error;
@end

@interface LocalSendPhotoPickerViewController ()
- (void)loadPhotoLibraryIfNeeded;
- (void)updateGridLayout;
- (BOOL)isClosed;
- (void)closePicker;
- (void)enumeratePhotoGroup:(ALAssetsGroup *)group;
- (void)addPhotoEntries:(NSArray *)entries;
- (void)enqueuePhotoEnumerationCompletion:(NSError *)error target:(LocalSendPhotoLoadTarget *)target;
- (void)finishPhotoEnumeration:(NSError *)error;
- (void)finishLoadingPhotos:(NSDictionary *)result;
- (void)updateSelectionStatus;
- (void)updateVisibleSelectionBadges;
- (void)sendSelectedPhotos:(id)sender;
- (void)cancelSelection:(id)sender;
@end

@implementation LocalSendPhotoLoadTarget
- (id)initWithPicker:(LocalSendPhotoPickerViewController *)picker {
    self = [super init];
    if (self) {
        _picker = [picker retain];
    }
    return self;
}
- (LocalSendPhotoPickerViewController *)picker {
    return _picker;
}
- (void)enumeratePhotoGroup:(ALAssetsGroup *)group {
    [_picker enumeratePhotoGroup:group];
}
- (void)finishPhotoEnumeration:(NSError *)error {
    [_picker finishPhotoEnumeration:error];
}
- (void)dealloc {
    if ([NSThread isMainThread]) {
        [_picker release];
    } else {
        [_picker performSelectorOnMainThread:@selector(release) withObject:nil waitUntilDone:NO];
    }
    [super dealloc];
}
@end

@implementation LocalSendPhotoPickerViewController

- (id)initWithDelegate:(id<LocalSendPhotoPickerDelegate>)delegate {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _columns = 4;
        _delegate = delegate;
        _library = [[ALAssetsLibrary alloc] init];
        _assets = [[NSMutableArray alloc] init];
        _photoLoadQueue = [[NSOperationQueue alloc] init];
        [_photoLoadQueue setMaxConcurrentOperationCount:1];
        _loadingEntries = [[NSMutableArray alloc] init];
        _loadedAssetURLs = [[NSMutableSet alloc] init];
        _selectedAssets = [[NSMutableArray alloc] init];
        _isLoadingPhotos = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Select Photos & Videos";
    self.tableView.rowHeight = 80;
    self.tableView.backgroundView = nil;
    self.tableView.backgroundColor = [UIColor blackColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self updateGridLayout];
    UIBarButtonItem *cancelButton =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelSelection:)];
    self.navigationItem.leftBarButtonItem = cancelButton;
    [cancelButton release];

    _sendButton = [[UIBarButtonItem alloc] initWithTitle:@"Send"
                                                   style:UIBarButtonItemStyleDone
                                                  target:self
                                                  action:@selector(sendSelectedPhotos:)];
    self.navigationItem.rightBarButtonItem = _sendButton;
    [self updateSelectionStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateGridLayout];
    [self loadPhotoLibraryIfNeeded];
}

- (void)updateGridLayout {
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) return;
    NSUInteger columns = LocalSendPhotoColumnsForWidth(width);
    CGFloat rowHeight = LocalSendPhotoTileSize(width, columns) + LocalSendPhotoGridRowPadding(width);
    if (_columns != columns || self.tableView.rowHeight != rowHeight) {
        _columns = columns;
        self.tableView.rowHeight = rowHeight;
        [self.tableView reloadData];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateGridLayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateGridLayout];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ||
           orientation == UIInterfaceOrientationPortrait;
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)orientation {
    [super didRotateFromInterfaceOrientation:orientation];
    // iOS 4 does not call viewDidLayoutSubviews.
    [self updateGridLayout];
}

- (BOOL)isClosed {
    @synchronized(self) {
        return _isClosed;
    }
}

- (void)closePicker {
    @synchronized(self) {
        _isClosed = YES;
        [_photoLoadQueue cancelAllOperations];
    }
}

- (void)loadPhotoLibraryIfNeeded {
    if (_hasStartedLoading || [self isClosed]) {
        return;
    }
    _hasStartedLoading = YES;
    LocalSendPhotoLoadTarget *target = [[[LocalSendPhotoLoadTarget alloc] initWithPicker:self] autorelease];
    [_library enumerateGroupsWithTypes:ALAssetsGroupAll | ALAssetsGroupLibrary
        usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            LocalSendPhotoPickerViewController *picker = [target picker];
            @synchronized(picker) {
                if (picker->_isClosed) {
                    *stop = YES;
                    return;
                }
                if (group == nil) {
                    [picker enqueuePhotoEnumerationCompletion:nil target:target];
                    return;
                }
                NSInvocationOperation *operation = [[NSInvocationOperation alloc]
                    initWithTarget:target selector:@selector(enumeratePhotoGroup:) object:group];
                [picker->_photoLoadQueue addOperation:operation];
                [operation release];
            }
        }
        failureBlock:^(NSError *error) {
            [[target picker] enqueuePhotoEnumerationCompletion:error target:target];
        }];
}

- (void)enumeratePhotoGroup:(ALAssetsGroup *)group {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([self isClosed]) {
        [pool drain];
        return;
    }
    NSMutableArray *batch = [[NSMutableArray alloc] initWithCapacity:LocalSendPhotoLoadingBatchSize];
    [group setAssetsFilter:[ALAssetsFilter allAssets]];
    NSUInteger remaining = (NSUInteger)MAX(0, [group numberOfAssets]);
    while (remaining > 0 && ![self isClosed]) {
        NSAutoreleasePool *batchPool = [[NSAutoreleasePool alloc] init];
        NSUInteger count = MIN(remaining, LocalSendPhotoLoadingBatchSize);
        remaining -= count;
        NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(remaining, count)];
        [group enumerateAssetsAtIndexes:indexes options:NSEnumerationReverse
            usingBlock:^(ALAsset *photoAsset, NSUInteger index, BOOL *stop) {
                if ([self isClosed]) {
                    *stop = YES;
                    return;
                }
                if (photoAsset == nil) {
                    return;
                }
                NSString *assetURL = [[[photoAsset defaultRepresentation] url] absoluteString];
                if ([assetURL length] != 0 && ![_loadedAssetURLs containsObject:assetURL]) {
                    [_loadedAssetURLs addObject:assetURL];
                    LocalSendPickerAsset *entry = [[LocalSendPickerAsset alloc] initWithAsset:photoAsset];
                    [_loadingEntries addObject:entry];
                    [batch addObject:entry];
                    [entry release];
                }
            }];
        if ([batch count] > 0 && ![self isClosed]) {
            [self performSelectorOnMainThread:@selector(addPhotoEntries:)
                                   withObject:batch waitUntilDone:YES];
        }
        [batch removeAllObjects];
        [batchPool drain];
    }
    [batch release];
    [pool drain];
}

- (void)addPhotoEntries:(NSArray *)entries {
    if ([self isClosed]) {
        return;
    }
    NSUInteger oldCount = [_assets count];
    NSUInteger oldRows = (oldCount + _columns - 1) / _columns;
    [_assets addObjectsFromArray:entries];
    if (![self isViewLoaded]) {
        return;
    }
    NSUInteger newRows = ([_assets count] + _columns - 1) / _columns;
    NSMutableArray *insertedRows = [NSMutableArray array];
    for (NSUInteger row = oldRows; row < newRows; row++) {
        [insertedRows addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    }
    [self.tableView beginUpdates];
    if (oldCount % _columns != 0) {
        [self.tableView reloadRowsAtIndexPaths:
            [NSArray arrayWithObject:[NSIndexPath indexPathForRow:oldRows - 1 inSection:0]]
                             withRowAnimation:UITableViewRowAnimationNone];
    }
    [self.tableView insertRowsAtIndexPaths:insertedRows withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView endUpdates];
}

- (void)enqueuePhotoEnumerationCompletion:(NSError *)error target:(LocalSendPhotoLoadTarget *)target {
    @synchronized(self) {
        if (_isClosed) {
            return;
        }
        NSInvocationOperation *operation = [[NSInvocationOperation alloc]
            initWithTarget:target selector:@selector(finishPhotoEnumeration:) object:error];
        for (NSOperation *pending in [_photoLoadQueue operations]) {
            [operation addDependency:pending];
        }
        [_photoLoadQueue addOperation:operation];
        [operation release];
    }
}

- (void)finishPhotoEnumeration:(NSError *)error {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (![self isClosed]) {
        NSArray *sortedEntries = [_loadingEntries sortedArrayUsingComparator:
            ^NSComparisonResult(LocalSendPickerAsset *first, LocalSendPickerAsset *second) {
                return [second->date compare:first->date];
            }];
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:sortedEntries forKey:@"entries"];
        if (error != nil) {
            [result setObject:error forKey:@"error"];
        }
        [self performSelectorOnMainThread:@selector(finishLoadingPhotos:)
                               withObject:result waitUntilDone:YES];
    }
    [_loadingEntries removeAllObjects];
    [_loadedAssetURLs removeAllObjects];
    [pool drain];
}

- (void)finishLoadingPhotos:(NSDictionary *)result {
    if ([self isClosed]) {
        return;
    }
    _isLoadingPhotos = NO;
    [_assets setArray:[result objectForKey:@"entries"]];
    [_photoLibraryError release];
    _photoLibraryError = [[result objectForKey:@"error"] retain];
    if ([self isViewLoaded]) {
        [self.tableView reloadData];
        [self updateSelectionStatus];
    }
}

- (void)updateSelectionStatus {
    NSUInteger selectedCount = [_selectedAssets count];
    _sendButton.enabled = selectedCount > 0;
    if (_photoLibraryError != nil) {
        self.navigationItem.prompt = [NSString
            stringWithFormat:@"Could not read photos: %@", [_photoLibraryError localizedDescription]];
        return;
    }
    self.navigationItem.prompt =
        [NSString stringWithFormat:@"%lu of %lu selected%@", (unsigned long)selectedCount,
                                   (unsigned long)LocalSendMaximumSelectedPhotos,
                                   _isLoadingPhotos ? @" · Loading…" : @""];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return ([_assets count] + _columns - 1) / _columns;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PhotoGrid";
    LocalSendPhotoGridCell *cell =
        (LocalSendPhotoGridCell *)[tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[[LocalSendPhotoGridCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:identifier] autorelease];
    }
    cell.delegate = self;
    cell.columnCount = _columns;
    for (NSUInteger columnIndex = 0; columnIndex < _columns; columnIndex++) {
        NSUInteger photoIndex = indexPath.row * _columns + columnIndex;
        if (photoIndex >= [_assets count]) {
            [cell hidePhotoAtColumn:columnIndex];
            continue;
        }
        LocalSendPickerAsset *entry = [_assets objectAtIndex:photoIndex];
        NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:entry->asset];
        NSUInteger selectionNumber = selectionIndex == NSNotFound ? 0 : selectionIndex + 1;
        CGImageRef thumbnail = [entry->asset respondsToSelector:@selector(aspectRatioThumbnail)]
            ? [entry->asset aspectRatioThumbnail] : [entry->asset thumbnail];
        [cell setPhotoAtColumn:columnIndex
                         image:thumbnail != NULL ? [UIImage imageWithCGImage:thumbnail] : nil
                    photoIndex:photoIndex
               selectionNumber:selectionNumber
                       isVideo:entry->isVideo];
    }
    return cell;
}

- (void)photoGridCell:(LocalSendPhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex {
    if (photoIndex >= [_assets count]) {
        return;
    }
    ALAsset *asset = ((LocalSendPickerAsset *)[_assets objectAtIndex:photoIndex])->asset;
    NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:asset];
    if (selectionIndex != NSNotFound) {
        [_selectedAssets removeObjectAtIndex:selectionIndex];
    } else if ([_selectedAssets count] < LocalSendMaximumSelectedPhotos) {
        [_selectedAssets addObject:asset];
    } else {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Too many items"
                                                        message:@"Send up to 100 photos and videos in one batch."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        [alert release];
    }
    [self updateSelectionStatus];
    [self updateVisibleSelectionBadges];
}

- (void)updateVisibleSelectionBadges {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForVisibleRows]) {
        LocalSendPhotoGridCell *cell = (LocalSendPhotoGridCell *)[self.tableView cellForRowAtIndexPath:indexPath];
        for (NSUInteger column = 0; column < _columns; column++) {
            NSUInteger photoIndex = indexPath.row * _columns + column;
            if (photoIndex >= [_assets count]) {
                break;
            }
            ALAsset *asset = ((LocalSendPickerAsset *)[_assets objectAtIndex:photoIndex])->asset;
            NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:asset];
            [cell setSelectionNumber:selectionIndex == NSNotFound ? 0 : selectionIndex + 1 atColumn:column];
        }
    }
}

- (void)sendSelectedPhotos:(id)sender {
    if ([_selectedAssets count] == 0) {
        return;
    }
    [self closePicker];
    id<LocalSendPhotoPickerDelegate> delegate = _delegate;
    _delegate = nil;
    [delegate photoPicker:self didSelectAssets:[NSArray arrayWithArray:_selectedAssets] library:_library];
}

- (void)cancelSelection:(id)sender {
    [self closePicker];
    id<LocalSendPhotoPickerDelegate> delegate = _delegate;
    _delegate = nil;
    [delegate photoPickerDidCancel:self];
}

- (void)viewDidUnload {
    self.navigationItem.rightBarButtonItem = nil;
    [_sendButton release];
    _sendButton = nil;
    [super viewDidUnload];
}

- (void)dealloc {
    [_library release];
    [_assets release];
    [_photoLoadQueue release];
    [_loadingEntries release];
    [_loadedAssetURLs release];
    [_selectedAssets release];
    [_sendButton release];
    [_photoLibraryError release];
    [super dealloc];
}
@end
