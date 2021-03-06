// Copyright 2010-2019 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OUIDocumentRenameSession.h"

@import OmniUI;

#import <OmniUIDocument/OUIDocumentPickerItemMetadataView.h>
#import <OmniDocumentStore/ODSErrors.h>
#import <OmniDocumentStore/ODSFileItem.h>
#import <OmniDocumentStore/ODSFolderItem.h>

#import "OUIDocumentPickerViewController-Internal.h"
#import "OUIDocumentPickerItemView-Internal.h"

RCS_ID("$Id$");

#if 0 && defined(DEBUG)
    #define RENAME_DEBUG(format, ...) NSLog(@"RENAME: " format, ## __VA_ARGS__)
#else
    #define RENAME_DEBUG(format, ...)
#endif

@interface OUIDocumentRenameSession () <UITextFieldDelegate, NSFilePresenter, OUIShieldViewDelegate>
@end

@implementation OUIDocumentRenameSession
{
    OUIDocumentPickerViewController *_picker;
    UITextField *_nameTextField;
    ODSItem *_item;
    OUIShieldView *_dimmingView;
    UIView *_animatingView;
    UIView *_opaqueBackingView;
    
    NSString *_originalName;
    NSOperationQueue *_filePresenterQueue;
    NSURL *_presentedFileURL; // Remember the original file URL in case there is an incoming rename; we want to be able to respond to NSFilePresenter -presentedItemURL correctly in this case.
    
    BOOL _isRegisteredAsFilePresenter;
    BOOL _isAttemptingRename;
    BOOL _isEndingEditing;
    BOOL _isFinishedRenaming;
    BOOL _needsHorizontalLayout;
    
    BOOL ignoreChangesMade;
    
    NSTimeInterval _animationDuration;
    UIViewAnimationCurve _animationCurve;
}

- initWithDocumentPicker:(OUIDocumentPickerViewController *)picker itemView:(OUIDocumentPickerItemView *)itemView nameTextField:(UITextField *)nameTextField;
{
    OBPRECONDITION(picker);
    OBPRECONDITION(itemView);
    
    if (!(self = [super init]))
        return nil;
    
    _picker = picker;
    _itemView = itemView;
    _item = itemView.item;
    OBASSERT([picker.folderItem.childItems member:_item] == _item);

    // We temporarily become the delegate.
    _nameTextField = nameTextField;
    _nameTextField.delegate = self;
    
    CGRect endingMetadataFrame = [self _frameForMetaDataViewForRenamingItemView:itemView];

    // Put up a dimming view and animate the item metadata view to twice its size so the text is easier to read
    self.origMetadataFrame = itemView.metadataView.frame;
    self.origItemFrame = itemView.frame;

    UIView *superview = _itemView.superview;
    [UIView performWithoutAnimation:^{
        _animatingView = [_itemView.metadataView viewForScalingStartFrame:self.origMetadataFrame endFrame:endingMetadataFrame];
        _dimmingView = [OUIShieldView shieldViewWithView:superview];
        _dimmingView.useBlur = YES;
        _dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; // Match on device rotation
        _dimmingView.opaque = NO;
        _dimmingView.alpha = 0;
        _dimmingView.delegate = self;
        [superview bringSubviewToFront:_itemView];
        [superview insertSubview:_dimmingView belowSubview:_itemView];
        _animatingView.frame = self.origMetadataFrame;
        _itemView.metadataView.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin;
        [superview bringSubviewToFront:_itemView.metadataView];
        
        // the opaqueBackingView is needed especially for the partial alpha blue background color on visio documents in non-pro installs
        _opaqueBackingView = [[UIView alloc] initWithFrame:_animatingView.frame];
        _opaqueBackingView.backgroundColor = [UIColor whiteColor];
        [itemView.metadataView.superview insertSubview:_opaqueBackingView belowSubview:itemView.metadataView];
        
        [superview insertSubview:_animatingView aboveSubview:_itemView.metadataView];
        itemView.metadataView.alpha = 0.0f;
        itemView.metadataView.frame = endingMetadataFrame;

        [itemView.superview setNeedsLayout];
        [itemView.superview layoutIfNeeded];
    }];

    OUIKeyboardNotifier *notifier = [OUIKeyboardNotifier sharedNotifier];

    // start a scroll if the ending frame will be behind the keyboard
    if ([superview isKindOfClass:[UIScrollView class]]) {
        [(UIScrollView*)superview scrollRectToVisibleAboveLastKnownKeyboard:endingMetadataFrame animated:YES completion:nil];
    }
    
    [UIView animateWithDuration:(notifier.lastAnimationDuration + 0.05)  // this slight extra length helps the separate animation curves of what we're using (to speed up the end of the animation and make the fade into reality feel less tacked on at the end) and what the keyboard is using feel more coordinated
                          delay:0
                        options:UIViewAnimationOptionOverrideInheritedDuration|UIViewAnimationOptionCurveEaseIn|UIViewAnimationOptionOverrideInheritedCurve
                     animations:^{
                         _itemView.frame = [self _centeredFrameForItemView:_itemView];
                         
                         _dimmingView.alpha = 1;
                         _animatingView.frame = endingMetadataFrame;
                         _opaqueBackingView.frame = endingMetadataFrame;
                         [itemView.metadataView animationsToPerformAlongsideScalingToHeight:endingMetadataFrame.size.height];
                         [_animatingView setNeedsLayout];
                     } completion:^(BOOL mainFinished) {
                         [UIView performWithoutAnimation:^{
                             self.origBackgroundColor = self.itemView.metadataView.backgroundColor;
                             itemView.metadataView.backgroundColor = [UIColor clearColor];
                         }];
                         itemView.metadataView.alpha = 1.0f;
                         itemView.metadataView.backgroundColor = self.origBackgroundColor;
                         [_animatingView removeFromSuperview];
                         _animatingView = nil;
                     }];
    
    _originalName = [_nameTextField.text copy];
    if (_item.type == ODSItemTypeFile && [_item isKindOfClass:[ODSFileItem class]]) {
        _nameTextField.text = [(ODSFileItem *)_item editingName];
    }
    
    // TODO: Maybe -fileURL should be on ODSFolderItem too.
    if (_item.type == ODSItemTypeFolder)
        _presentedFileURL = [[_item.scope.documentsURL URLByAppendingPathComponent:((ODSFolderItem *)_item).relativePath isDirectory:YES] copy];
    else
        _presentedFileURL = [((ODSFileItem *)_item).fileURL copy];
    
    _filePresenterQueue = [[NSOperationQueue alloc] init];
    _filePresenterQueue.name = @"OUIDocumentRenameSession NSFilePresenter notifications";
    _filePresenterQueue.maxConcurrentOperationCount = 1;

    // Load these with some experimentally determined values to match the keyboard animation. If the keyboard does notify us, we'll use whatever it sent for real.
    _animationDuration = 0.25;
    _animationCurve = UIViewAnimationCurveEaseInOut;

    // This will retain us, so we cannot -removeFilePresenter: in dealloc.
    [NSFileCoordinator addFilePresenter:self];
    _isRegisteredAsFilePresenter = YES;
    
    return self;
}

- (CGRect)_centeredFrameForItemView:(OUIDocumentPickerItemView *)itemView
{
    // we always want to be in the same position with respect to the screen bounds, which has to be translated into the scrollview's coordinate system
    
    CGRect fixedFrame = itemView.frame;
    fixedFrame.origin.x = (_picker.view.bounds.size.width - itemView.frame.size.width) / 2;
    fixedFrame.origin.y = 120;

    if (_needsHorizontalLayout) {
        fixedFrame.origin.y = 60;  // we have less space, so use less space
        fixedFrame.origin.x = 0.2 * fixedFrame.size.width;  // stick the item view to the left side of the scrollview
    } else {
        fixedFrame.origin.x = (_picker.view.bounds.size.width - fixedFrame.size.width) / 2;  // center the item view horizontally
    }
    
    return [_picker.view convertRect:fixedFrame toView:_picker.mainScrollView];
}

- (CGRect)_frameForMetaDataViewForRenamingItemView:(OUIDocumentPickerItemView *)itemView
{
    OUIKeyboardNotifier *notifier = [OUIKeyboardNotifier sharedNotifier];
    
    CGRect frame = itemView.metadataView.frame;
    frame.size.height *= 2;
    frame.size.width = ceil(itemView.superview.bounds.size.width * .6);
    
    CGRect itemFrame = [self _centeredFrameForItemView:itemView];
    CGFloat padding = itemFrame.size.height * 0.2;
    frame.origin.x = floor(itemFrame.origin.x - (frame.size.width - itemFrame.size.width) / 2.0);
    frame.origin.y = floor(CGRectGetMaxY(itemFrame) + padding);
    
    // try to make sure we won't be going below the keyboard
    CGFloat bottomOfLargeFrame = CGRectGetMaxY(frame);
    CGFloat lowerBoundOkForLargeFrame = [notifier minimumYPositionOfLastKnownKeyboardInView:itemView.superview];
    CGFloat diff = bottomOfLargeFrame - lowerBoundOkForLargeFrame;
    if (diff > 0) {
        // try a horizontal layout instead
        _needsHorizontalLayout = YES;
        itemFrame = [self _centeredFrameForItemView:itemView];
        frame.origin.x = CGRectGetMaxX(itemFrame) + padding;
        frame.origin.y = CGRectGetMaxY(itemFrame) - CGRectGetHeight(frame);
        frame.size.width = itemView.superview.frame.size.width - frame.origin.x - padding;
    }
    
    return frame;
}

- (void)dealloc;
{
    
    if (_animatingView) {
        [_animatingView removeFromSuperview];
        _animatingView = nil;
    }
    
    if (_opaqueBackingView) {
        [_opaqueBackingView removeFromSuperview];
        _opaqueBackingView = nil;
    }
    
    OBPRECONDITION(_nameTextField.delegate != self);
    OBPRECONDITION(!_isRegisteredAsFilePresenter);
    
    _dimmingView.delegate = nil;
}

- (void)cancelRenaming;
{
    RENAME_DEBUG(@"cancelRenaming");
    
    // Put the original name back. This will cause -_done: to bail on the rename.
    _nameTextField.text = _originalName;
    
    [self _done:nil];
}

- (void)layoutDimmingView;
{
    UIView *superview = _itemView.superview;
    _dimmingView.frame = superview.bounds;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldEndEditing:(UITextField *)textField;
{
    RENAME_DEBUG(@"textFieldShouldEndEditing:");
    
    if (ignoreChangesMade)
        return YES;
    
    // We need an extra BOOL here to let us know we should really go ahead and end the rename.
    // The rename operation doesn't call our completion block until the file presenter queue has performed the -presentedItemDidMoveToURL:, but in that case the file item will have only updated its _filePresenterURL (which must update immediately and which can be accessed from any thead) and has only enqueued a main thread operation to update its _displayedFileURL (which is what sources the -name method below). The ordering of operations will still be correct since our completion block will still get called on the main thread after the display name is updated, but we can't tell that here.
    NSString *newName = [textField text];
    BOOL isEmpty = [NSString isEmptyString:newName];
    BOOL usingEditingName = (_item.type == ODSItemTypeFile && [_item isKindOfClass:[ODSFileItem class]]);
    NSString *nameTest = usingEditingName ? [(ODSFileItem *)_item editingName] : _item.name;

    BOOL isSameName = isEmpty || ([nameTest localizedCompare:newName] == NSOrderedSame);
    if (_isAttemptingRename || _isFinishedRenaming || isSameName) {
        if (isSameName) {
            _isFinishedRenaming = YES;
            
            // Might be the "same" due to deleting everything
            if (isEmpty || (usingEditingName && !_isEndingEditing))
                _nameTextField.text = _originalName;
        }
        
        if (_isEndingEditing == NO) // Avoid infinite recursion
            [self _done:nil];
        RENAME_DEBUG(@"Bail on empty/same name");
        return YES;
    }
        
    // Otherwise, start the rename and return NO for now, but remember that we've tried already.
    _isAttemptingRename = YES;
    
    [_picker _renameItem:_item baseName:newName completionHandler:^(NSError *errorOrNil){
        if (errorOrNil) {
            // if ([errorOrNil hasUnderlyingErrorDomain:ODSErrorDomain code:ODSFilenameAlreadyInUse])
            // or Some other error which may not be correctable
            // we need to bail in either case because the new animated renaming experience can't handle not being finished
            _isFinishedRenaming = YES;
            [_nameTextField endEditing:YES];
        } else {
            // We are all good. Clear this now so that we don't get reentrantly called.
            _isFinishedRenaming = YES;
            [self _done:nil];
        }
    }];
    
    return NO;
}

- (void)textFieldDidEndEditing:(NSNotification *)note;
{
    RENAME_DEBUG(@"did end editing");
    RENAME_DEBUG(@"  _isAttemptingRename %d", _isAttemptingRename);
    
    OBASSERT(_nameTextField.delegate == self);
    _nameTextField.delegate = nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField{
    [textField resignFirstResponder];
    return NO;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string;
{
    // <bug://bugs/61021>
    NSRange r = [string rangeOfString:@"/"];
    if (r.location != NSNotFound) {
        return NO;
    }
    
    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField;
{
    RENAME_DEBUG(@"textFieldShouldClear:");
    
    [_nameTextField becomeFirstResponder];
    [_nameTextField setDelegate:self];  // seems to be a hardware keyboard bug where clearing the text clears the delegate if no keyboard is showing
    
    return YES;
}

#pragma mark - NSFilePresenter

- (NSURL *)presentedItemURL;
{
    NSURL *result = nil;
    
    @synchronized(self) {
        result = _presentedFileURL;
    }
    
    return result;
}

- (NSOperationQueue *)presentedItemOperationQueue;
{
    OBPRECONDITION(_filePresenterQueue);
    return _filePresenterQueue;
}

// We don't currently attempt to reset our in-progress edit of the file name if we see an incoming rename. We just bail
- (void)presentedItemDidMoveToURL:(NSURL *)newURL;
{
    @synchronized(self) {
        if (OFISEQUAL(_presentedFileURL, newURL))
            return;

        // Acknowledge the change, in case we are asked when we -removeFilePresenter:
        _presentedFileURL = [newURL copy];
    }
    
    // But then cancel ourselves (unless we are the one doing the rename)
    if (_isAttemptingRename == NO) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [self cancelRenaming];
        }];
    }
}

- (void)presentedItemDidChange;
{
    // This gets spuriously sent after renames sometimes, but if there is an incoming edit from iCloud (or iTunes, once that works again), discard our rename.
    if (_isAttemptingRename == NO) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [self cancelRenaming];
        }];
    }
}

- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))completionHandler;
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [self cancelRenaming];
        
        if (completionHandler)
            completionHandler(nil);
    }];
}

#pragma mark - OUIShieldViewDelegate

- (void)shieldViewWasTouched:(OUIShieldView *)shieldView;
{
    [self _done:shieldView];
}

- (void)endRenaming:(BOOL)ignoreChanges
{
    if (ignoreChanges) {
        [self _dismissFromScreen:NO];
        ignoreChangesMade = YES;
        [_nameTextField endEditing:YES];
        _isFinishedRenaming = YES;
        if (_isRegisteredAsFilePresenter) {
            _isRegisteredAsFilePresenter = NO;
            [NSFileCoordinator removeFilePresenter:self];
        }
    } else {
        [self _done:nil];
    }
}

#pragma mark - Private

- (void)_dismissFromScreen:(BOOL)animated
{
    UIView *dimmingView = _dimmingView;
    
    OUIKeyboardNotifier *notifier = [OUIKeyboardNotifier sharedNotifier];
    
    if (animated) {
        // get the animating view on screen
        [UIView performWithoutAnimation:^{
            CGRect startFrame = _itemView.metadataView.frame;
            
            UIView *weNeedToGenerateTheSnapshotSoTheViewKnowsToResetItselfToRegularSize = [_itemView.metadataView viewForScalingStartFrame:startFrame endFrame:self.origMetadataFrame];
            if (!_animatingView) {  // but if we already have an animating view, we need to use it for the animation instead of the view we just generated
                _animatingView = weNeedToGenerateTheSnapshotSoTheViewKnowsToResetItselfToRegularSize;
            }
            _itemView.metadataView.backgroundColor = [UIColor clearColor];
            _itemView.metadataView.alpha = 0.0f;
            [_itemView.metadataView.superview addSubview:_animatingView];
        }];
        
        // animate the frame changes
        [UIView animateWithDuration:notifier.lastAnimationDuration
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionOverrideInheritedOptions | UIViewAnimationOptionCurveEaseIn
                         animations:^{
                             dimmingView.alpha = 0;
                             _itemView.frame = self.origItemFrame;
                             self.origMetadataFrame = CGRectInset(self.origMetadataFrame, 1, 1);
                             _animatingView.frame = self.origMetadataFrame;
                             _opaqueBackingView.frame = self.origMetadataFrame;
                             [_itemView.metadataView animationsToPerformAlongsideScalingToHeight:self.origMetadataFrame.size.height];
                         } completion:^(BOOL mainFinished){
                             _itemView.metadataView.frame = self.origMetadataFrame;
                             [dimmingView removeFromSuperview];
                             _dimmingView = nil;
                             _itemView.metadataView.alpha = 0.6f;
                             _animatingView.alpha = 0.0f;
                             _itemView.metadataView.alpha = 1.0f;
                             _itemView.metadataView.backgroundColor = self.origBackgroundColor;
                             [_opaqueBackingView removeFromSuperview];
                             _opaqueBackingView = nil;
                             [_animatingView removeFromSuperview];
                             [_itemView reattachMetaDataView];
                         }];
    } else {
        _itemView.frame = self.origItemFrame;
        self.origMetadataFrame = CGRectInset(self.origMetadataFrame, 1, 1);
        [_itemView.metadataView animationsToPerformAlongsideScalingToHeight:self.origMetadataFrame.size.height];
        _itemView.metadataView.frame = self.origMetadataFrame;
        _itemView.metadataView.doubleSizeFonts = NO;
        [_opaqueBackingView removeFromSuperview];
        _opaqueBackingView = nil;
        _dimmingView.alpha = 0.0f;
        [_dimmingView removeFromSuperview];
        _dimmingView = nil;
        [_itemView reattachMetaDataView];
    }
    
}

- (void)_done:(id)sender;
{
    // Let the keyboard drive the animation
    RENAME_DEBUG(@"-_done: calling -endEditing:");
    RENAME_DEBUG(@"  _isAttemptingRename %d", _isAttemptingRename);

    [self _dismissFromScreen:YES];
    
    // Depending on how the user ends editing, we can get called first or -textFieldShouldEndEditing:.
    _isEndingEditing = YES;
    BOOL rc = [_nameTextField endEditing:NO];
    _isEndingEditing = NO;
    
    if (rc == NO && _isAttemptingRename) {
        // Our -textFieldShouldEndEditing: call rejected the edit so that we want wait to see if the rename actually worked before ending editing.
        RENAME_DEBUG(@"Rename is in progress -- waiting for it to finish or fail");
        return;
    }
    
    RENAME_DEBUG(@"-_done:, after -endEditing:...");
    RENAME_DEBUG(@"  _isAttemptingRename %d", _isAttemptingRename);

    OBASSERT(_isFinishedRenaming);
    
    OBRetainAutorelease(self); // Make sure we don't get deallocated immediately since our call stack still has stuff to do.
    
    OBASSERT(_isRegisteredAsFilePresenter);
    if (_isRegisteredAsFilePresenter) {
        _isRegisteredAsFilePresenter = NO;
        [NSFileCoordinator removeFilePresenter:self];
    }
}

@end
