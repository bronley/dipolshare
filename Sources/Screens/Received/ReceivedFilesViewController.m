#import "ReceivedFilesViewController.h"
#import "Receiver.h"
#import "Formatting.h"
#import "ReceivedEmptyView.h"
#import "PhotoSaveOverlay.h"
#import <ImageIO/ImageIO.h>
#import "LocalSendPhotoPreviewViewController.h"

static const unsigned long long MaximumClipboardFileSize = 1024ULL * 1024ULL;

@interface ReceivedFilesViewController ()
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
- (void)sharePreviewPhoto:(LocalSendPhotoPreviewViewController *)preview;
- (BOOL)photoPreviewVisible;
- (UIView *)fileActionHostView;
- (void)printSelectedPhoto;
- (BOOL)fileCanSaveToPhotos:(NSDictionary *)file;
- (void)toggleFileSelection:(id)sender;
- (void)selectAllFiles:(id)sender;
- (void)saveSelectedPhotos:(id)sender;
- (void)updateSelectionControls;
- (void)showPhotoSaveOverlay;
- (void)hidePhotoSaveOverlay;
- (void)confirmDeleteSelectedFiles:(id)sender;
- (void)deleteFilesAtPaths:(NSArray *)paths;
- (void)dismissDeleteConfirmation;
@end

@implementation ReceivedFilesViewController

- (id)initWithReceiveStatus:(NSString *)status active:(BOOL)active {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _selectedFilePaths = [[NSMutableSet alloc] init];
        _receiveStatus = [status copy];
        _isReceivingFiles = active;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(filesChanged:)
                                                     name:ReceivedFilesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(receiveUpdated:)
                                                     name:ReceiveProgressNotification
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
    _emptyStateView = [[ReceivedEmptyView alloc] initWithFrame:self.tableView.bounds];
    _emptyStateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self reloadFiles];
    [self updateReceiveStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFiles];
    [[Receiver sharedReceiver] markReceivedFilesSeen];
    [self refreshBadge];
    [self updateReceiveStatus];
}

- (void)filesChanged:(NSNotification *)notification {
    if ([self isViewLoaded]) {
        [self reloadFiles];
    }
    BOOL paneVisible = [self isViewLoaded] && self.view.window != nil;
    BOOL selectedTab = self.navigationController.tabBarController.selectedViewController == self.navigationController;
    if ((selectedTab || (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad && paneVisible)) &&
        self.navigationController.visibleViewController == self && self.modalViewController == nil) {
        [[Receiver sharedReceiver] markReceivedFilesSeen];
    }
    [self refreshBadge];
}

- (void)refreshBadge {
    NSUInteger unseenCount = [[Receiver sharedReceiver] unseenReceivedFileCount];
    self.navigationController.tabBarItem.badgeValue =
        unseenCount == 0 ? nil
                         : unseenCount > 99 ? @"99+"
                                            : [NSString stringWithFormat:@"%u", (unsigned int)unseenCount];
}

- (void)reloadFiles {
    [self.tableView setEditing:NO animated:NO];
    [_files release];
    _files = [[[Receiver sharedReceiver] receivedFiles] copy];
    self.tableView.backgroundView = [_files count] == 0 ? _emptyStateView : nil;
    self.tableView.separatorStyle =
        [_files count] == 0 ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
    NSMutableSet *availableFiles = [NSMutableSet set];
    for (NSDictionary *file in _files) {
        NSString *path = [file objectForKey:@"path"];
        if (path != nil) [availableFiles addObject:path];
    }
    [_selectedFilePaths intersectSet:availableFiles];
    [self updateSelectionControls];
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
    [self updateSelectionControls];
}

- (void)cancelReceive:(id)sender {
    if (_isReceivingFiles) {
        [[Receiver sharedReceiver] cancelCurrentTransfer];
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
                         FormattedFileSize([[file objectForKey:@"size"] unsignedLongLongValue]),
                         date];
    BOOL selected = [_selectedFilePaths containsObject:[file objectForKey:@"path"]];
    cell.accessoryType = _selectingFiles
        ? (selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone)
        : UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    cell.accessibilityTraits = selected ? (cell.accessibilityTraits | UIAccessibilityTraitSelected)
                                       : (cell.accessibilityTraits & ~UIAccessibilityTraitSelected);
    return cell;
}

- (BOOL)selectedFileCanCopyText {
    NSString *type = [[_selectedFile objectForKey:@"type"] lowercaseString];
    NSString *extension = [[[_selectedFile objectForKey:@"name"] pathExtension] lowercaseString];
    BOOL isText = [type hasPrefix:@"text/"] || [extension isEqualToString:@"txt"];
    return isText &&
           [[_selectedFile objectForKey:@"size"] unsignedLongLongValue] <= MaximumClipboardFileSize;
}

- (BOOL)selectedFileCanSaveToPhotos {
    return [self fileCanSaveToPhotos:_selectedFile];
}

- (BOOL)fileCanSaveToPhotos:(NSDictionary *)file {
    NSString *extension = [[[file objectForKey:@"name"] pathExtension] lowercaseString];
    return [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"] ||
           [extension isEqualToString:@"jpe"] || [extension isEqualToString:@"png"];
}

- (void)updateSelectionControls {
    NSUInteger selectedPhotoCount = 0;
    for (NSDictionary *file in _files) {
        if ([self fileCanSaveToPhotos:file] && [_selectedFilePaths containsObject:[file objectForKey:@"path"]]) {
            selectedPhotoCount++;
        }
    }
    self.title = _selectingFiles
        ? [NSString stringWithFormat:@"%lu Selected", (unsigned long)[_selectedFilePaths count]] : @"Received";
    UIBarButtonItem *select = [[[UIBarButtonItem alloc] initWithTitle:_selectingFiles ? @"Cancel" : @"Select"
        style:UIBarButtonItemStyleBordered target:self action:@selector(toggleFileSelection:)] autorelease];
    select.enabled = !_photoSaver.isSaving && (_selectingFiles || [_files count] > 0);
    self.navigationItem.rightBarButtonItem = select;
    self.navigationItem.leftBarButtonItem = nil;
    NSMutableArray *items = [NSMutableArray array];
    if (_selectingFiles) {
        UIBarButtonItem *all = [[[UIBarButtonItem alloc]
            initWithTitle:[_selectedFilePaths count] == [_files count] ? @"Clear" : @"Select All"
            style:UIBarButtonItemStyleBordered target:self action:@selector(selectAllFiles:)] autorelease];
        all.enabled = !_photoSaver.isSaving && [_files count] > 0;
        self.navigationItem.leftBarButtonItem = all;
        UIBarButtonItem *save = [[[UIBarButtonItem alloc] initWithTitle:@"Save Photos"
            style:UIBarButtonItemStyleDone target:self action:@selector(saveSelectedPhotos:)] autorelease];
        save.enabled = selectedPhotoCount > 0 && !_photoSaver.isSaving;
        [items addObject:save];
        UIBarButtonItem *space = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
        [items addObject:space];
        UIBarButtonItem *trash = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
            target:self action:@selector(confirmDeleteSelectedFiles:)] autorelease];
        trash.accessibilityLabel = @"Delete selected files";
        trash.enabled = [_selectedFilePaths count] > 0 && !_photoSaver.isSaving;
        [items addObject:trash];
    }
    if (_isReceivingFiles) {
        UIBarButtonItem *space = [[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil] autorelease];
        [items addObject:space];
        if (_cancelReceiveButton != nil) [items addObject:_cancelReceiveButton];
    }
    self.toolbarItems = items;
    [self.navigationController setToolbarHidden:!(_selectingFiles || _isReceivingFiles) animated:NO];
}

- (void)toggleFileSelection:(id)sender {
    if (_photoSaver.isSaving || _fileActionsSheet != nil || _deleteConfirmationAlert != nil) return;
    [_documentInteractionController dismissMenuAnimated:NO];
    [self.tableView setEditing:NO animated:NO];
    _selectingFiles = !_selectingFiles;
    [_selectedFilePaths removeAllObjects];
    [self updateSelectionControls];
    [self.tableView reloadData];
}

- (void)selectAllFiles:(id)sender {
    if (_photoSaver.isSaving || !_selectingFiles) return;
    NSMutableSet *paths = [NSMutableSet set];
    for (NSDictionary *file in _files) {
        NSString *path = [file objectForKey:@"path"];
        if (path != nil) [paths addObject:path];
    }
    if ([_selectedFilePaths isEqualToSet:paths]) [_selectedFilePaths removeAllObjects];
    else [_selectedFilePaths setSet:paths];
    [self updateSelectionControls];
    [self.tableView reloadData];
}

- (void)saveSelectedPhotos:(id)sender {
    if (_photoSaver.isSaving || !_selectingFiles || [_selectedFilePaths count] == 0) return;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSDictionary *file in _files) {
        NSString *path = [file objectForKey:@"path"];
        if ([self fileCanSaveToPhotos:file] && [_selectedFilePaths containsObject:path]) [paths addObject:path];
    }
    if (_photoSaver == nil) {
        _photoSaver = [[PhotoLibrarySaver alloc] init];
        _photoSaver.delegate = self;
    }
    if (![_photoSaver savePhotosAtPaths:paths]) return;
    [_savingPhotoPaths release];
    _savingPhotoPaths = [paths copy];
    [self showPhotoSaveOverlay];
    [(PhotoSaveOverlay *)_photoSaveOverlay setCompletedPhotos:0 total:[paths count]];
    [self updateSelectionControls];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !_selectingFiles && !_photoSaver.isSaving && _fileActionsSheet == nil && _deleteConfirmationAlert == nil;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self tableView:tableView canEditRowAtIndexPath:indexPath]
        ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Delete";
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [_swipedFilePath release];
    _swipedFilePath = indexPath.row < [_files count]
        ? [[[_files objectAtIndex:indexPath.row] objectForKey:@"path"] copy] : nil;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [_swipedFilePath release];
    _swipedFilePath = nil;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete ||
        ![self tableView:tableView canEditRowAtIndexPath:indexPath] || _swipedFilePath == nil) return;
    NSArray *paths = [NSArray arrayWithObject:_swipedFilePath];
    [tableView setEditing:NO animated:YES];
    [self deleteFilesAtPaths:paths];
}

- (void)confirmDeleteSelectedFiles:(id)sender {
    if (!_selectingFiles || [_selectedFilePaths count] == 0 || _photoSaver.isSaving || _deleteConfirmationAlert != nil) return;
    _pendingDeletePaths = [[_selectedFilePaths allObjects] copy];
    NSUInteger count = [_pendingDeletePaths count];
    NSString *title = [NSString stringWithFormat:@"Delete %lu file%@?", (unsigned long)count, count == 1 ? @"" : @"s"];
    _deleteConfirmationAlert = [[UIAlertView alloc] initWithTitle:title
        message:@"This permanently removes the selected files from Received. Copies saved to Photos are kept."
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Delete", nil];
    [_deleteConfirmationAlert show];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (alertView != _deleteConfirmationAlert) return;
    NSArray *paths = [_pendingDeletePaths retain];
    _deleteConfirmationAlert.delegate = nil;
    [_deleteConfirmationAlert release];
    _deleteConfirmationAlert = nil;
    [_pendingDeletePaths release];
    _pendingDeletePaths = nil;
    if (buttonIndex == 1 && !_photoSaver.isSaving &&
        [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self deleteFilesAtPaths:paths];
    }
    [paths release];
}

- (void)dismissDeleteConfirmation {
    _deleteConfirmationAlert.delegate = nil;
    [_deleteConfirmationAlert dismissWithClickedButtonIndex:0 animated:NO];
    [_deleteConfirmationAlert release];
    _deleteConfirmationAlert = nil;
    [_pendingDeletePaths release];
    _pendingDeletePaths = nil;
}

- (void)deleteFilesAtPaths:(NSArray *)paths {
    if (_photoSaver.isSaving) return;
    [_documentInteractionController dismissMenuAnimated:NO];
    NSString *message = nil;
    NSArray *failed = [[Receiver sharedReceiver] deleteReceivedFilesAtPaths:paths errorMessage:&message];
    NSMutableSet *deleted = [NSMutableSet setWithArray:paths];
    [deleted minusSet:[NSSet setWithArray:failed]];
    [_selectedFilePaths minusSet:deleted];
    if ([_selectedFilePaths count] == 0) _selectingFiles = NO;
    if ([deleted containsObject:[_selectedFile objectForKey:@"path"]]) {
        [_selectedFile release];
        _selectedFile = nil;
        [_previewURL release];
        _previewURL = nil;
    }
    [self reloadFiles];
    [self refreshBadge];
    if (message != nil) [self showMessage:message title:[failed count] > 0 ? @"Could not delete files" : @"Received files"];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self dismissDeleteConfirmation];
    [super viewWillDisappear:animated];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_fileActionsSheet != nil || _photoSaver.isSaving) {
        return;
    }
    NSDictionary *file = [_files objectAtIndex:indexPath.row];
    if (_selectingFiles) {
        NSString *path = [file objectForKey:@"path"];
        if (path == nil) return;
        if ([_selectedFilePaths containsObject:path]) [_selectedFilePaths removeObject:path];
        else [_selectedFilePaths addObject:path];
        [self updateSelectionControls];
        [tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    [_selectedFile release];
    _selectedFile = [file copy];
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
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        CGRect rowRect = [tableView rectForRowAtIndexPath:indexPath];
        [_fileActionsSheet showFromRect:rowRect inView:tableView animated:YES];
    } else {
        [_fileActionsSheet showInView:self.navigationController.view];
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
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
    } else if ([buttonTitle isEqualToString:@"Print"]) {
        [self printSelectedPhoto];
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
    if (_photoSaver.isSaving) {
        return;
    }
    NSURL *fileURL = [self selectedFileURL];
    if (fileURL == nil) {
        return;
    }
    if ([self selectedFileCanSaveToPhotos]) {
        CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)fileURL, NULL);
        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailFromImageAlways,
            [NSNumber numberWithBool:YES], (NSString *)kCGImageSourceCreateThumbnailWithTransform,
            [NSNumber numberWithInt:2048], (NSString *)kCGImageSourceThumbnailMaxPixelSize, nil];
        CGImageRef thumbnail = source == NULL ? NULL :
            CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
        if (source != NULL) CFRelease(source);
        if (thumbnail == NULL) {
            [self showMessage:@"This photo could not be opened." title:@"Cannot preview photo"];
            return;
        }
        UIImage *image = [UIImage imageWithCGImage:thumbnail];
        CGImageRelease(thumbnail);
        LocalSendPhotoPreviewViewController *photo = [[LocalSendPhotoPreviewViewController alloc]
            initWithImage:image title:[_selectedFile objectForKey:@"name"]
            target:self action:@selector(sharePreviewPhoto:)];
        [_photoPreviewNavigation release];
        _photoPreviewNavigation = [[UINavigationController alloc] initWithRootViewController:photo];
        _photoPreviewNavigation.navigationBar.barStyle = UIBarStyleBlack;
        _photoPreviewNavigation.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.view.window.rootViewController presentModalViewController:_photoPreviewNavigation animated:YES];
        [photo release];
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
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        preview.modalPresentationStyle = UIModalPresentationFullScreen;
        UIViewController *workspace = self.view.window.rootViewController;
        [workspace presentModalViewController:preview animated:YES];
    } else {
        [self.navigationController pushViewController:preview animated:YES];
    }
    [preview release];
}

- (BOOL)photoPreviewVisible {
    return [_photoPreviewNavigation isViewLoaded] && _photoPreviewNavigation.view.window != nil;
}

- (UIView *)fileActionHostView {
    if ([self photoPreviewVisible]) return _photoPreviewNavigation.view;
    UIView *host = self.view.window.rootViewController.view;
    return host != nil ? host : self.navigationController.view;
}

- (void)sharePreviewPhoto:(LocalSendPhotoPreviewViewController *)preview {
    if (_fileActionsSheet != nil || _photoSaver.isSaving) return;
    _fileActionsSheet = [[UIActionSheet alloc] initWithTitle:[_selectedFile objectForKey:@"name"]
        delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
        otherButtonTitles:@"Save to Photos", @"Open In…", nil];
    if ([UIPrintInteractionController isPrintingAvailable]) {
        [_fileActionsSheet addButtonWithTitle:@"Print"];
    }
    _fileActionsSheet.cancelButtonIndex = [_fileActionsSheet addButtonWithTitle:@"Cancel"];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        [_fileActionsSheet showFromBarButtonItem:preview.shareButton animated:YES];
    } else {
        [_fileActionsSheet showInView:preview.navigationController.view];
    }
}

- (void)printSelectedPhoto {
    NSURL *url = [self selectedFileURL];
    if (url == nil) return;
    if (![UIPrintInteractionController canPrintURL:url]) {
        [self showMessage:@"This photo cannot be printed." title:@"Cannot print photo"];
        return;
    }
    UIPrintInteractionController *printer = [UIPrintInteractionController sharedPrintController];
    printer.printingItem = url;
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        LocalSendPhotoPreviewViewController *preview =
            (LocalSendPhotoPreviewViewController *)_photoPreviewNavigation.topViewController;
        [printer presentFromBarButtonItem:preview.shareButton animated:YES completionHandler:nil];
    } else {
        [printer presentAnimated:YES completionHandler:nil];
    }
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return _previewURL == nil ? 0 : 1;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return _previewURL;
}

- (void)openSelectedFile {
    if (_photoSaver.isSaving) {
        return;
    }
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
    BOOL shown;
    if ([self photoPreviewVisible]) {
        LocalSendPhotoPreviewViewController *preview =
            (LocalSendPhotoPreviewViewController *)_photoPreviewNavigation.topViewController;
        shown = [_documentInteractionController presentOpenInMenuFromBarButtonItem:preview.shareButton animated:YES];
    } else {
        shown = [_documentInteractionController
            presentOpenInMenuFromRect:CGRectMake(0, self.view.bounds.size.height - 1,
                                                 self.view.bounds.size.width, 1)
                               inView:self.view animated:YES];
    }
    if (!shown) {
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
        [[attributes objectForKey:NSFileSize] unsignedLongLongValue] > MaximumClipboardFileSize) {
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
    if (_photoSaver.isSaving || ![self selectedFileCanSaveToPhotos]) {
        return;
    }
    if (_photoSaver == nil) {
        _photoSaver = [[PhotoLibrarySaver alloc] init];
        _photoSaver.delegate = self;
    }
    if (![_photoSaver savePhotoAtPath:[_selectedFile objectForKey:@"path"]]) {
        return;
    }
    [self showPhotoSaveOverlay];
}

- (void)showPhotoSaveOverlay {
    UIView *host = [self fileActionHostView];
    _photoSaveOverlay = [[PhotoSaveOverlay alloc] initWithFrame:host.bounds];
    [host addSubview:_photoSaveOverlay];
    [_photoSaveOverlay layoutIfNeeded];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
}

- (void)hidePhotoSaveOverlay {
    [_photoSaveOverlay removeFromSuperview];
    [_photoSaveOverlay release];
    _photoSaveOverlay = nil;
}

- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didFinishWithErrorMessage:(NSString *)errorMessage {
    if (saver != _photoSaver) return;
    [self hidePhotoSaveOverlay];
    [self updateSelectionControls];
    [self showMessage:errorMessage == nil ? @"The photo is now in the Camera Roll." : errorMessage
                title:errorMessage == nil ? @"Photo saved" : @"Cannot save photo"];
}

- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didCompletePhotos:(NSUInteger)completed total:(NSUInteger)total {
    if (saver != _photoSaver) return;
    [(PhotoSaveOverlay *)_photoSaveOverlay setCompletedPhotos:completed total:total];
}

- (void)photoLibrarySaver:(PhotoLibrarySaver *)saver didFinishBatchWithSavedCount:(NSUInteger)savedCount
             failedPaths:(NSArray *)failedPaths errorMessage:(NSString *)errorMessage {
    if (saver != _photoSaver) return;
    [self hidePhotoSaveOverlay];
    [_selectedFilePaths minusSet:[NSSet setWithArray:_savingPhotoPaths]];
    [_selectedFilePaths addObjectsFromArray:failedPaths];
    [_savingPhotoPaths release];
    _savingPhotoPaths = nil;
    _selectingFiles = [_selectedFilePaths count] > 0;
    [self reloadFiles];
    NSString *message = [NSString stringWithFormat:@"%lu photo%@ saved to the Camera Roll.",
        (unsigned long)savedCount, savedCount == 1 ? @"" : @"s"];
    if ([failedPaths count] > 0) {
        message = [message stringByAppendingFormat:@"\n\n%lu could not be saved and remain selected.\n%@",
            (unsigned long)[failedPaths count], errorMessage ?: @"Please try again."];
    }
    [self showMessage:message title:[failedPaths count] > 0 ? @"Save incomplete" : @"Photos saved"];
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
    [self dismissDeleteConfirmation];
    [_savingPhotoPaths release];
    [_swipedFilePath release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _fileActionsSheet.delegate = nil;
    [_fileActionsSheet dismissWithClickedButtonIndex:_fileActionsSheet.cancelButtonIndex animated:NO];
    [_fileActionsSheet release];
    _documentInteractionController.delegate = nil;
    [_documentInteractionController dismissMenuAnimated:NO];
    [_documentInteractionController release];
    [_files release];
    [_selectedFilePaths release];
    [_selectedFile release];
    [_previewURL release];
    [_cancelReceiveButton release];
    [_emptyStateView release];
    [_receiveStatus release];
    _photoSaver.delegate = nil;
    [_photoSaver release];
    [_photoSaveOverlay removeFromSuperview];
    [_photoSaveOverlay release];
    [_photoPreviewNavigation release];
    [super dealloc];
}
@end
