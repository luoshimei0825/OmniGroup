// Copyright 2010-2017 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import <OmniUI/OUIActivityIndicator.h>

#import <OmniFoundation/OFCFCallbacks.h>
#import <OmniUI/UIView-OUIExtensions.h>

RCS_ID("$Id$");

@implementation OUIActivityIndicator
{
    UIView *_view;
    UIColor *_color;
    
    UIActivityIndicatorView *_activityIndicator;
    NSUInteger _showCount;
}

static CFMutableDictionaryRef ViewToActivityIndicator = NULL;

+ (void)initialize;
{
    OBINITIALIZE;
    
    ViewToActivityIndicator = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &OFNonOwnedPointerDictionaryKeyCallbacks, &OFNonOwnedPointerDictionaryValueCallbacks);
}

- initWithView:(UIView *)view color:(UIColor *)color;
{
    OBPRECONDITION(view);
    OBPRECONDITION(view.window); // should already be on screen

    if (!(self = [super init]))
        return nil;
    
    _view = view;
    _color = [color copy];
     
    return self;
}

- (void)dealloc;
{
    if (_activityIndicator) {
        OBASSERT_NOT_REACHED("-hide should really have been called the right number of times");
        [self _remove];
    }
}

- (void)_add;
{
    OBPRECONDITION(_activityIndicator == nil);
    OBPRECONDITION(CFDictionaryGetValue(ViewToActivityIndicator, (__bridge CFTypeRef)_view) == nil);

    CFDictionaryAddValue(ViewToActivityIndicator, (__bridge CFTypeRef)_view, (__bridge const void *)(self));

    [UIView performWithoutAnimation:^{
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
        _activityIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;
        
        if (_color)
            _activityIndicator.color = _color;
        
        _activityIndicator.center = _view.center;
        
        _activityIndicator.layer.zPosition = 2;
        [_activityIndicator startAnimating];
        _activityIndicator.alpha = 0;
        
        [_view.superview addSubview:_activityIndicator];
    }];
    
    // Just fade this in
    [UIView animateWithDuration:0.3 animations:^{
        _activityIndicator.alpha = 1;
    }];
}

- (void)_remove;
{
    OBPRECONDITION(_activityIndicator);
    OBPRECONDITION((__bridge OUIActivityIndicator *)CFDictionaryGetValue(ViewToActivityIndicator, (__bridge CFTypeRef)_view) == self);
    
    CFDictionaryRemoveValue(ViewToActivityIndicator, (__bridge CFTypeRef)_view);
    
    [_activityIndicator stopAnimating];
    [_activityIndicator removeFromSuperview];
    _activityIndicator = nil;
}

- (void)_show;
{
    if (_showCount == 0)
        [self _add];
    _showCount++;
}

- (void)hide;
{
    if (_showCount == 0) {
        OBASSERT_NOT_REACHED("Called -hide too many times");
        return;
    }
    
    _showCount--;
    
    if (_showCount == 0)
        [self _remove];
}

+ (OUIActivityIndicator *)showActivityIndicatorInView:(UIView *)view;
{
    return [self showActivityIndicatorInView:view withColor:[UIColor whiteColor]];
}

+ (OUIActivityIndicator *)showActivityIndicatorInView:(UIView *)view withColor:(UIColor *)color;
{
    if (!view.window) {
        return nil;
    }
    OUIActivityIndicator *indicator = (__bridge OUIActivityIndicator *)CFDictionaryGetValue(ViewToActivityIndicator, (__bridge CFTypeRef)view);
    if (!indicator)
        indicator = [[OUIActivityIndicator alloc] initWithView:view color:color];
    
    [indicator _show];
    
    return indicator;
}

@end
