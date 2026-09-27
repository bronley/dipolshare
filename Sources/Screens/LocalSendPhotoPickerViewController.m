#import "LocalSendPhotoPickerViewController.h"

static const NSUInteger LocalSendMaximumSelectedPhotos = 100;
static const NSUInteger LocalSendPhotoLoadingRefreshInterval = 24;

@interface LocalSendPhotoPickerViewController ()
- (void)loadPhotoLibraryIfNeeded;
- (void)addPhotoAsset:(ALAsset *)asset;
- (void)sortPhotosNewestFirst;
- (void)finishLoadingPhotos;
- (void)showPhotoLibraryError:(NSError *)error;
- (void)updateSelectionStatus;
- (void)sendSelectedPhotos:(id)sender;
- (void)cancelSelection:(id)sender;
@end

@implementation LocalSendPhotoPickerViewController

- (id)initWithDelegate:(id<LocalSendPhotoPickerDelegate>)delegate {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _delegate = delegate;
        _library = [[ALAssetsLibrary alloc] init];
        _assets = [[NSMutableArray alloc] init];
        _loadedAssetURLs = [[NSMutableSet alloc] init];
        _selectedAssets = [[NSMutableArray alloc] init];
        _isLoadingPhotos = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Select Photos";
    self.tableView.rowHeight = 80;
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
    [self loadPhotoLibraryIfNeeded];
}

- (void)loadPhotoLibraryIfNeeded {
    if (_hasStartedLoading || _isClosed) {
        return;
    }
    _hasStartedLoading = YES;
    [_library enumerateGroupsWithTypes:ALAssetsGroupAll | ALAssetsGroupLibrary
        usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
            if (_isClosed) {
                *stop = YES;
                return;
            }
            if (group == nil) {
                [self performSelectorOnMainThread:@selector(finishLoadingPhotos)
                                       withObject:nil
                                    waitUntilDone:NO];
                return;
            }
            [group setAssetsFilter:[ALAssetsFilter allPhotos]];
            [group enumerateAssetsWithOptions:NSEnumerationReverse
                usingBlock:^(ALAsset *asset, NSUInteger index, BOOL *assetStop) {
                if (_isClosed) {
                    *assetStop = YES;
                    return;
                }
                if (asset != nil) {
                    [self performSelectorOnMainThread:@selector(addPhotoAsset:)
                                           withObject:asset
                                        waitUntilDone:NO];
                }
            }];
        }
        failureBlock:^(NSError *error) {
            [self performSelectorOnMainThread:@selector(showPhotoLibraryError:)
                                   withObject:error
                                waitUntilDone:NO];
        }];
}

- (void)addPhotoAsset:(ALAsset *)asset {
    if (_isClosed) {
        return;
    }
    NSString *assetURL = [[[asset defaultRepresentation] url] absoluteString];
    if ([assetURL length] == 0 || [_loadedAssetURLs containsObject:assetURL]) {
        return;
    }
    [_loadedAssetURLs addObject:assetURL];
    [_assets addObject:asset];
    if (!_isLoadingPhotos) {
        [self sortPhotosNewestFirst];
    }
    if ([self isViewLoaded] &&
        (!_isLoadingPhotos || [_assets count] % LocalSendPhotoLoadingRefreshInterval == 0)) {
        [self.tableView reloadData];
    }
}

- (void)finishLoadingPhotos {
    if (_isClosed) {
        return;
    }
    _isLoadingPhotos = NO;
    [self sortPhotosNewestFirst];
    if ([self isViewLoaded]) {
        [self.tableView reloadData];
        [self updateSelectionStatus];
    }
}

- (void)showPhotoLibraryError:(NSError *)error {
    if (_isClosed) {
        return;
    }
    _isLoadingPhotos = NO;
    [self sortPhotosNewestFirst];
    [_photoLibraryError release];
    _photoLibraryError = [error retain];
    if ([self isViewLoaded]) {
        [self.tableView reloadData];
        [self updateSelectionStatus];
    }
}

- (void)sortPhotosNewestFirst {
    [_assets sortUsingComparator:^NSComparisonResult(id first, id second) {
        id firstDate = [(ALAsset *)first valueForProperty:ALAssetPropertyDate];
        id secondDate = [(ALAsset *)second valueForProperty:ALAssetPropertyDate];
        if (![firstDate isKindOfClass:[NSDate class]]) {
            firstDate = [NSDate distantPast];
        }
        if (![secondDate isKindOfClass:[NSDate class]]) {
            secondDate = [NSDate distantPast];
        }
        return [(NSDate *)secondDate compare:(NSDate *)firstDate];
    }];
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
    return ([_assets count] + LocalSendPhotosPerRow - 1) / LocalSendPhotosPerRow;
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
    for (NSUInteger columnIndex = 0; columnIndex < LocalSendPhotosPerRow; columnIndex++) {
        NSUInteger photoIndex = indexPath.row * LocalSendPhotosPerRow + columnIndex;
        if (photoIndex >= [_assets count]) {
            [cell hidePhotoAtColumn:columnIndex];
            continue;
        }
        ALAsset *asset = [_assets objectAtIndex:photoIndex];
        NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:asset];
        NSUInteger selectionNumber = selectionIndex == NSNotFound ? 0 : selectionIndex + 1;
        [cell setPhotoAtColumn:columnIndex
                         image:[UIImage imageWithCGImage:[asset thumbnail]]
                    photoIndex:photoIndex
               selectionNumber:selectionNumber];
    }
    return cell;
}

- (void)photoGridCell:(LocalSendPhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex {
    if (photoIndex >= [_assets count]) {
        return;
    }
    ALAsset *asset = [_assets objectAtIndex:photoIndex];
    NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:asset];
    if (selectionIndex != NSNotFound) {
        [_selectedAssets removeObjectAtIndex:selectionIndex];
    } else if ([_selectedAssets count] < LocalSendMaximumSelectedPhotos) {
        [_selectedAssets addObject:asset];
    } else {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Too many photos"
                                                        message:@"Send up to 100 photos in one batch."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        [alert release];
    }
    [self updateSelectionStatus];
    [self.tableView reloadData];
}

- (void)sendSelectedPhotos:(id)sender {
    if ([_selectedAssets count] == 0) {
        return;
    }
    _isClosed = YES;
    id<LocalSendPhotoPickerDelegate> delegate = _delegate;
    _delegate = nil;
    [delegate photoPicker:self didSelectAssets:[NSArray arrayWithArray:_selectedAssets] library:_library];
}

- (void)cancelSelection:(id)sender {
    _isClosed = YES;
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
    [_loadedAssetURLs release];
    [_selectedAssets release];
    [_sendButton release];
    [_photoLibraryError release];
    [super dealloc];
}
@end
