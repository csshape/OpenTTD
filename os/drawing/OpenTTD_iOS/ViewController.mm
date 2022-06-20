//
//  ViewController.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"
#import "ViewController.h"

#include "ios_wnd.h"

extern CALayer *_cocoa_touch_layer;

@interface ViewController ()
@property (readonly, nonatomic) OTTD_CocoaView *openGLView;
@end

@implementation ViewController

- (OTTD_CocoaView*)openGLView {
    if ([self.view isKindOfClass:[OTTD_CocoaView class]]) {
        return (OTTD_CocoaView*)self.view;
    }
    
    return nil;
}

//- (void)loadView {
//    CGRect rect = [UIScreen mainScreen].bounds;
//    self.view = [[OTTD_CocoaView alloc] initWithFrame:rect];
//}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor magentaColor];
    
    _cocoa_touch_layer.frame = self.view.bounds;
    [self.view.layer addSublayer:_cocoa_touch_layer];
    [[AppDelegate sharedInstance] resizeGameView:self.view.bounds.size];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [[AppDelegate sharedInstance] resizeGameView:size];
}

- (void)viewDidLayoutSubviews {
    _cocoa_touch_layer.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (void)draw {
    
}

@end
