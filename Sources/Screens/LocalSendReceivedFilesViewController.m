#import "LocalSendReceivedFilesViewController.h"
#import "LocalSendReceiver.h"
#import "LocalSendFormatting.h"

static const unsigned long long LocalSendMaximumClipboardFileSize = 1024ULL * 1024ULL;
static const unsigned long long LocalSendMaximumPhotoAlbumFileSize = 64ULL * 1024ULL * 1024ULL;

@interface LocalSendReceivedEmptyView : UIView {
    UIImageView *_satelliteImageView;
    UILabel *_messageLabel;
}
@end

@implementation LocalSendReceivedEmptyView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        self.backgroundColor = [UIColor whiteColor];
        _satelliteImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Satellite"]];
        _satelliteImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_satelliteImageView];

        _messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _messageLabel.backgroundColor = [UIColor clearColor];
        _messageLabel.textColor = [UIColor darkGrayColor];
        _messageLabel.font = [UIFont systemFontOfSize:16.0f];
        _messageLabel.textAlignment = UITextAlignmentCenter;
        _messageLabel.text = @"No received files yet.";
        [self addSubview:_messageLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat iconSize = MIN(142.0f, width - 32.0f);
    CGFloat groupHeight = iconSize + 16.0f + 24.0f;
    CGFloat top = MAX(0.0f, (height - groupHeight) / 2.0f);
    _satelliteImageView.frame = CGRectMake((width - iconSize) / 2.0f, top, iconSize, iconSize);
    _messageLabel.frame = CGRectMake(12.0f, top + iconSize + 16.0f, width - 24.0f, 24.0f);
}

- (void)dealloc {
    [_satelliteImageView release];
    [_messageLabel release];
    [super dealloc];
}

@end

@interface LocalSendReceivedFilesViewController ()
- (void)reloadFiles;
- (void)filesChanged:(NSNotification *)notification;
- (void)receiveUpdated:(NSNotification *)notification;
- (void)updateReceiveStatus;
- (void)cancelReceive:(id)sender;
- (void)showMessage:(NSString *)message title:(NSString *)title;
- (BOOL)selectedFileCanCopyText;
- (BOOL)selectedFileCanSaveToPhotos;
- (void)previewSelectedFile;
- (NSURL *)selectedFileURL;
- (void)openSelectedFile;
- (void)copySelectedText;
- (void)saveSelectedPhoto;
- (void)photoSaveFinished:(NSString *)errorMessage;
@end

@implementation LocalSendReceivedFilesViewController

- (id)initWithReceiveStatus:(NSString *)status active:(BOOL)active {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _receiveStatus = [status copy];
        _isReceivingFiles = active;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(filesChanged:)
                                                     name:LocalSendReceivedFilesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveUpdated:)
                                                     name:LocalSendReceiveProgressNotification
                                                   object:nil];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Received";
    self.tableView.rowHeight = 58.0;

    _cancelReceiveButton = [[UIBarButtonItem alloc] initWithTitle:@"Cancel receive"
                                                            style:UIBarButtonItemStyleBordered
                                                           target:self
                                                           action:@selector(cancelReceive:)];
    UIBarButtonItem *space =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                      target:nil
                                                      action:nil];
    self.toolbarItems = [NSArray arrayWithObjects:space, _cancelReceiveButton, nil];
    [space release];

    _emptyStateView = [[LocalSendReceivedEmptyView alloc] initWithFrame:self.tableView.bounds];
    _emptyStateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self reloadFiles];
    [self updateReceiveStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFiles];
    [[LocalSendReceiver sharedReceiver] markReceivedFilesSeen];
    [self refreshBadge];
    [self updateReceiveStatus];
}

- (void)filesChanged:(NSNotification *)notification {
    if ([self isViewLoaded]) {
        [self reloadFiles];
    }
    if (self.navigationController.tabBarController.selectedViewController == self.navigationController &&
        self.navigationController.visibleViewController == self && self.presentedViewController == nil) {
        [[LocalSendReceiver sharedReceiver] markReceivedFilesSeen];
    }
    [self refreshBadge];
}

- (void)refreshBadge {
    NSUInteger unseenCount = [[LocalSendReceiver sharedReceiver] unseenReceivedFileCount];
    self.navigationController.tabBarItem.badgeValue =
        unseenCount == 0 ? nil
                         : unseenCount > 99 ? @"99+"
                                            : [NSString stringWithFormat:@"%u", (unsigned int)unseenCount];
}

- (void)reloadFiles {
    [_files release];
    _files = [[[LocalSendReceiver sharedReceiver] receivedFiles] copy];
    self.tableView.backgroundView = [_files count] == 0 ? _emptyStateView : nil;
    self.tableView.separatorStyle =
        [_files count] == 0 ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
    [self.tableView reloadData];
}

- (void)receiveUpdated:(NSNotification *)notification {
    NSString *status = [[notification userInfo] objectForKey:@"status"];
    [_receiveStatus release];
    _receiveStatus = [status copy];
    _isReceivingFiles = [[[notification userInfo] objectForKey:@"active"] boolValue];
    if ([self isViewLoaded]) {
        [self updateReceiveStatus];
    }
}

- (void)updateReceiveStatus {
    self.navigationItem.prompt = [_receiveStatus length] > 0 ? _receiveStatus : nil;
    _cancelReceiveButton.enabled = _isReceivingFiles;
    [self.navigationController setToolbarHidden:!_isReceivingFiles animated:NO];
}

- (void)cancelReceive:(id)sender {
    if (_isReceivingFiles) {
        [[LocalSendReceiver sharedReceiver] cancelCurrentTransfer];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_files count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"ReceivedFile";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:identifier] autorelease];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
        cell.textLabel.lineBreakMode = UILineBreakModeMiddleTruncation;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *file = [_files objectAtIndex:indexPath.row];
    cell.textLabel.text = [file objectForKey:@"name"];
    NSString *date = @"";
    if ([[file objectForKey:@"date"] isKindOfClass:[NSDate class]]) {
        date = [NSDateFormatter localizedStringFromDate:[file objectForKey:@"date"]
                                              dateStyle:NSDateFormatterShortStyle
                                              timeStyle:NSDateFormatterShortStyle];
    }
    cell.detailTextLabel.text = [NSString
        stringWithFormat:@"%@ · %@",
                         LocalSendFormattedFileSize([[file objectForKey:@"size"] unsignedLongLongValue]),
                         date];
    return cell;
}

- (BOOL)selectedFileCanCopyText {
    NSString *type = [[_selectedFile objectForKey:@"type"] lowercaseString];
    NSString *extension = [[[_selectedFile objectForKey:@"name"] pathExtension] lowercaseString];
    BOOL isText = [type hasPrefix:@"text/"] || [extension isEqualToString:@"txt"];
    return isText &&
           [[_selectedFile objectForKey:@"size"] unsignedLongLongValue] <= LocalSendMaximumClipboardFileSize;
}

- (BOOL)selectedFileCanSaveToPhotos {
    NSString *extension = [[[_selectedFile objectForKey:@"name"] pathExtension] lowercaseString];
    return [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"] ||
           [extension isEqualToString:@"jpe"] || [extension isEqualToString:@"png"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_fileActionsSheet != nil) {
        return;
    }
    [_selectedFile release];
    _selectedFile = [[_files objectAtIndex:indexPath.row] copy];
    _fileActionsSheet = [[UIActionSheet alloc] initWithTitle:[_selectedFile objectForKey:@"name"]
                                                    delegate:self
                                           cancelButtonTitle:nil
                                      destructiveButtonTitle:nil
                                           otherButtonTitles:@"Preview", @"Open In…", nil];
    if ([self selectedFileCanSaveToPhotos]) {
        [_fileActionsSheet addButtonWithTitle:@"Save to Photos"];
    }
    if ([self selectedFileCanCopyText]) {
        [_fileActionsSheet addButtonWithTitle:@"Copy Text"];
    }
    _fileActionsSheet.cancelButtonIndex = [_fileActionsSheet addButtonWithTitle:@"Cancel"];
    [_fileActionsSheet showInView:self.navigationController.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (actionSheet != _fileActionsSheet) {
        return;
    }
    NSInteger cancelIndex = actionSheet.cancelButtonIndex;
    NSString *buttonTitle = buttonIndex < 0 || buttonIndex >= [actionSheet numberOfButtons] ||
                                    buttonIndex == cancelIndex
                                ? nil
                                : [[actionSheet buttonTitleAtIndex:buttonIndex] copy];
    _fileActionsSheet.delegate = nil;
    [_fileActionsSheet release];
    _fileActionsSheet = nil;
    if (buttonTitle == nil) {
        return;
    }
    if ([buttonTitle isEqualToString:@"Preview"]) {
        [self previewSelectedFile];
    } else if ([buttonTitle isEqualToString:@"Open In…"]) {
        [self openSelectedFile];
    } else if ([buttonTitle isEqualToString:@"Save to Photos"]) {
        [self saveSelectedPhoto];
    } else if ([buttonTitle isEqualToString:@"Copy Text"]) {
        [self copySelectedText];
    }
    [buttonTitle release];
}

- (void)actionSheetCancel:(UIActionSheet *)actionSheet {
    if (actionSheet != _fileActionsSheet) {
        return;
    }
    _fileActionsSheet.delegate = nil;
    [_fileActionsSheet release];
    _fileActionsSheet = nil;
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (NSURL *)selectedFileURL {
    NSString *path = [_selectedFile objectForKey:@"path"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [NSURL fileURLWithPath:path];
    }
    [self showMessage:@"This file is no longer available." title:@"Cannot open file"];
    [self reloadFiles];
    return nil;
}

- (void)previewSelectedFile {
    NSURL *fileURL = [self selectedFileURL];
    if (fileURL == nil) {
        return;
    }
    if (![QLPreviewController canPreviewItem:fileURL]) {
        [self showMessage:
                  @"A preview is not available for this file type. Try Open In to use another installed app."
                    title:@"No preview available"];
        return;
    }
    [_previewURL release];
    _previewURL = [fileURL retain];
    QLPreviewController *preview = [[QLPreviewController alloc] init];
    preview.dataSource = self;
    [self.navigationController pushViewController:preview animated:YES];
    [preview release];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return _previewURL == nil ? 0 : 1;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return _previewURL;
}

- (void)openSelectedFile {
    NSURL *fileURL = [self selectedFileURL];
    if (fileURL == nil) {
        return;
    }
    [_documentInteractionController dismissMenuAnimated:NO];
    _documentInteractionController.delegate = nil;
    [_documentInteractionController release];
    _documentInteractionController =
        [[UIDocumentInteractionController interactionControllerWithURL:fileURL] retain];
    _documentInteractionController.delegate = self;
    if (![_documentInteractionController
            presentOpenInMenuFromRect:CGRectMake(0, self.view.bounds.size.height - 1,
                                                 self.view.bounds.size.width, 1)
                               inView:self.view
                             animated:YES]) {
        [self showMessage:@"No installed app can open this file. It remains saved in Received."
                    title:@"No compatible app"];
    }
}

- (void)copySelectedText {
    if (![self selectedFileCanCopyText]) {
        return;
    }
    NSString *path = [_selectedFile objectForKey:@"path"];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (attributes == nil ||
        [[attributes objectForKey:NSFileSize] unsignedLongLongValue] > LocalSendMaximumClipboardFileSize) {
        [self showMessage:@"Only text files up to 1 MB can be copied." title:@"Cannot copy text"];
        return;
    }
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text == nil) {
        [self showMessage:@"This file could not be read as UTF-8 text." title:@"Cannot copy text"];
        return;
    }
    [UIPasteboard generalPasteboard].string = text;
    [self showMessage:@"The file's text is now on the clipboard." title:@"Text copied"];
}

- (void)saveSelectedPhoto {
    if (![self selectedFileCanSaveToPhotos]) {
        return;
    }
    if (_isSavingPhoto) {
        [self showMessage:@"Wait for the current photo to finish saving." title:@"Saving photo"];
        return;
    }
    NSURL *fileURL = [self selectedFileURL];
    if (fileURL == nil) {
        return;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[fileURL path] error:NULL];
    unsigned long long size = [[attributes objectForKey:NSFileSize] unsignedLongLongValue];
    if (size == 0 || size > LocalSendMaximumPhotoAlbumFileSize) {
        [self showMessage:@"This photo is too large to save on this device (64 MB limit)."
                    title:@"Cannot save photo"];
        return;
    }
    _photoSaveData = [[NSData alloc] initWithContentsOfFile:[fileURL path]];
    if ([_photoSaveData length] != size) {
        [_photoSaveData release];
        _photoSaveData = nil;
        [self showMessage:@"The photo could not be read." title:@"Cannot save photo"];
        return;
    }
    if (_photoLibrary == nil) {
        _photoLibrary = [[ALAssetsLibrary alloc] init];
    }
    _isSavingPhoto = YES;
    [_photoLibrary writeImageDataToSavedPhotosAlbum:_photoSaveData
                                           metadata:nil
                                    completionBlock:^(NSURL *assetURL, NSError *error) {
                                        NSString *errorMessage = error == nil && assetURL != nil
                                                                     ? nil
                                                                     : error == nil ? @"The photo could not be saved."
                                                                                    : [error localizedDescription];
                                        [self performSelectorOnMainThread:@selector(photoSaveFinished:)
                                                               withObject:errorMessage
                                                            waitUntilDone:NO];
                                    }];
}

- (void)photoSaveFinished:(NSString *)errorMessage {
    _isSavingPhoto = NO;
    [_photoSaveData release];
    _photoSaveData = nil;
    [self showMessage:errorMessage == nil ? @"The photo is now in the Camera Roll." : errorMessage
                title:errorMessage == nil ? @"Photo saved" : @"Cannot save photo"];
}

- (void)viewDidUnload {
    [_cancelReceiveButton release];
    _cancelReceiveButton = nil;
    [_emptyStateView release];
    _emptyStateView = nil;
    self.toolbarItems = nil;
    [super viewDidUnload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _fileActionsSheet.delegate = nil;
    [_fileActionsSheet dismissWithClickedButtonIndex:_fileActionsSheet.cancelButtonIndex animated:NO];
    [_fileActionsSheet release];
    _documentInteractionController.delegate = nil;
    [_documentInteractionController dismissMenuAnimated:NO];
    [_documentInteractionController release];
    [_files release];
    [_selectedFile release];
    [_previewURL release];
    [_cancelReceiveButton release];
    [_emptyStateView release];
    [_receiveStatus release];
    [_photoLibrary release];
    [_photoSaveData release];
    [super dealloc];
}
@end
