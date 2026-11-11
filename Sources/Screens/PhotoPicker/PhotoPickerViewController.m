#import "PhotoPickerViewController.h"
#import "PickerAsset.h"
#import "LocalSendPhotoGridLayout.h"

static const NSUInteger MaximumSelectedPhotos = 100;

@interface PhotoPickerViewController ()
- (void)updateGridLayout;
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
        _columns = 4;
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
    [_photoLoader start];
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
        [_photoLoader cancel];
    }
}

- (void)photoLibraryLoader:(PhotoLibraryLoader *)loader didLoadEntries:(NSArray *)entries {
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
    return ([_assets count] + _columns - 1) / _columns;
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
    cell.columnCount = _columns;
    for (NSUInteger columnIndex = 0; columnIndex < _columns; columnIndex++) {
        NSUInteger photoIndex = indexPath.row * _columns + columnIndex;
        if (photoIndex >= [_assets count]) {
            [cell hidePhotoAtColumn:columnIndex];
            continue;
        }
        PickerAsset *entry = [_assets objectAtIndex:photoIndex];
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
        for (NSUInteger column = 0; column < _columns; column++) {
            NSUInteger photoIndex = indexPath.row * _columns + column;
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
