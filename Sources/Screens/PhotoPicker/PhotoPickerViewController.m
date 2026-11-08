#import "PhotoPickerViewController.h"
#import "PickerAsset.h"

static const NSUInteger MaximumSelectedPhotos = 100;

@interface PhotoPickerViewController ()
- (BOOL)isClosed;
- (void)closePicker;
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didLoadEntries:(NSArray *)entries;
- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didFinishWithEntries:(NSArray *)entries error:(NSError *)error;
- (void)updateSelectionStatus;
- (void)updateVisibleSelectionBadges;
- (void)sendSelectedPhotos:(id)sender;
- (void)cancelSelection:(id)sender;
@end

@implementation PhotoPickerViewController

- (id)initWithDelegate:(id<PhotoPickerDelegate>)delegate {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _delegate = delegate;
        _photoLoader = [[PhotoLibraryLoader alloc] init];
        _photoLoader.delegate = self;
        _assets = [[NSMutableArray alloc] init];
        _selectedAssets = [[NSMutableArray alloc] init];
        _isLoadingPhotos = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Select Photos & Videos";
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
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_photoLoader start];
}

- (BOOL)isClosed {
    @synchronized(self) {
        return _isClosed;
    }
}

- (void)closePicker {
    @synchronized(self) {
        _isClosed = YES;
        [_photoLoader cancel];
    }
}

- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didLoadEntries:(NSArray *)entries {
    if ([self isClosed]) {
        return;
    }
    NSUInteger oldCount = [_assets count];
    NSUInteger oldRows = (oldCount + PhotosPerRow - 1) / PhotosPerRow;
    [_assets addObjectsFromArray:entries];
    if (![self isViewLoaded]) {
        return;
    }
    NSUInteger newRows = ([_assets count] + PhotosPerRow - 1) / PhotosPerRow;
    NSMutableArray *insertedRows = [NSMutableArray array];
    for (NSUInteger row = oldRows; row < newRows; row++) {
        [insertedRows addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    }
    [self.tableView beginUpdates];
    if (oldCount % PhotosPerRow != 0) {
        [self.tableView reloadRowsAtIndexPaths:
            [NSArray arrayWithObject:[NSIndexPath indexPathForRow:oldRows - 1 inSection:0]]
                             withRowAnimation:UITableViewRowAnimationNone];
    }
    [self.tableView insertRowsAtIndexPaths:insertedRows withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView endUpdates];
}

- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didFinishWithEntries:(NSArray *)entries error:(NSError *)error {
    if ([self isClosed]) {
        return;
    }
    _isLoadingPhotos = NO;
    [_assets setArray:entries];
    [_photoLibraryError release];
    _photoLibraryError = [error retain];
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
                                   (unsigned long)MaximumSelectedPhotos,
                                   _isLoadingPhotos ? @" · Loading…" : @""];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return ([_assets count] + PhotosPerRow - 1) / PhotosPerRow;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PhotoGrid";
    PhotoGridCell *cell =
        (PhotoGridCell *)[tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[[PhotoGridCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:identifier] autorelease];
    }
    cell.delegate = self;
    for (NSUInteger columnIndex = 0; columnIndex < PhotosPerRow; columnIndex++) {
        NSUInteger photoIndex = indexPath.row * PhotosPerRow + columnIndex;
        if (photoIndex >= [_assets count]) {
            [cell hidePhotoAtColumn:columnIndex];
            continue;
        }
        PickerAsset *entry = [_assets objectAtIndex:photoIndex];
        NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:entry->asset];
        NSUInteger selectionNumber = selectionIndex == NSNotFound ? 0 : selectionIndex + 1;
        [cell setPhotoAtColumn:columnIndex
                         image:[UIImage imageWithCGImage:[entry->asset thumbnail]]
                    photoIndex:photoIndex
               selectionNumber:selectionNumber
                       isVideo:entry->isVideo];
    }
    return cell;
}

- (void)photoGridCell:(PhotoGridCell *)cell didSelectPhotoAtIndex:(NSUInteger)photoIndex {
    if (photoIndex >= [_assets count]) {
        return;
    }
    ALAsset *asset = ((PickerAsset *)[_assets objectAtIndex:photoIndex])->asset;
    NSUInteger selectionIndex = [_selectedAssets indexOfObjectIdenticalTo:asset];
    if (selectionIndex != NSNotFound) {
        [_selectedAssets removeObjectAtIndex:selectionIndex];
    } else if ([_selectedAssets count] < MaximumSelectedPhotos) {
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
        PhotoGridCell *cell = (PhotoGridCell *)[self.tableView cellForRowAtIndexPath:indexPath];
        for (NSUInteger column = 0; column < PhotosPerRow; column++) {
            NSUInteger photoIndex = indexPath.row * PhotosPerRow + column;
            if (photoIndex >= [_assets count]) {
                break;
            }
            ALAsset *asset = ((PickerAsset *)[_assets objectAtIndex:photoIndex])->asset;
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
    id<PhotoPickerDelegate> delegate = _delegate;
    _delegate = nil;
    [delegate photoPicker:self didSelectAssets:[NSArray arrayWithArray:_selectedAssets] library:_photoLoader.library];
}

- (void)cancelSelection:(id)sender {
    [self closePicker];
    id<PhotoPickerDelegate> delegate = _delegate;
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
    [_photoLoader cancel];
    [_photoLoader release];
    [_assets release];
    [_selectedAssets release];
    [_sendButton release];
    [_photoLibraryError release];
    [super dealloc];
}
@end
