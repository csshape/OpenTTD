//
//  ViewController.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "GameInputView.h"

#include "ios_wnd.h"

extern CALayer *_cocoa_touch_layer;

@interface ViewController ()
@property (readonly, nonatomic) AppDelegate *appDelegate;
@property (strong, nonatomic) GameInputView *inputView;
@end

@implementation ViewController

- (AppDelegate*)appDelegate {
    id appDelegate = [UIApplication sharedApplication].delegate;
    if ([appDelegate isKindOfClass:[AppDelegate class]]) {
        return (AppDelegate*)appDelegate;
    }
    
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    
    GameInputView* inputView = [[GameInputView alloc] initWithFrame:self.view.bounds];
    inputView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:inputView];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [inputView startUp];
    });
    
    self.inputView = inputView;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self.appDelegate resizeGameView:size];
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

- (void)updateLayer {
    _cocoa_touch_layer.frame = self.view.bounds;
    [self.view.layer addSublayer:_cocoa_touch_layer];
    [self.appDelegate resizeGameView:self.view.bounds.size];
    
    [self.view bringSubviewToFront:self.inputView];
}

@end
