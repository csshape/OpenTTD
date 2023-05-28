//
//  ViewController.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#if defined (IOS)
#import <UIKit/UIKit.h>

@interface ViewController : UIViewController

@property (strong, nonatomic) UIView *cocoaView;

- (void)updateLayer;
- (UIImage *)getImageFromView;
- (void)setDarkScreen:(BOOL)on;

@end

#endif

