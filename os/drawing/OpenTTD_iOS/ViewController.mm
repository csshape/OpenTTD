//
//  ViewController.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"
#import "ViewController.h"

//extern CALayer *_cocoa_touch_layer;

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
//    _cocoa_touch_layer.frame = self.view.bounds;
//    [self.view.layer addSublayer:_cocoa_touch_layer];
    [[AppDelegate sharedInstance] resizeGameView:self.view.bounds.size];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [[AppDelegate sharedInstance] resizeGameView:size];
}

- (void)viewDidLayoutSubviews {
//    _cocoa_touch_layer.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

@end
