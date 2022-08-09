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
    BOOL isLandscape = UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation);
    [self.appDelegate resizeGameView:size isLandscape:isLandscape];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (void)updateLayer {
    BOOL isLandscape = UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation);
    
    [self.appDelegate resizeGameView:self.view.bounds.size isLandscape:isLandscape];
    [self.view bringSubviewToFront:self.inputView];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.inputView pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.inputView pressesEnded:presses withEvent:event];
}

@end
