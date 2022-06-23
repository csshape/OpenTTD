//
//  AppDelegate.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

- (void)resizeGameView:(CGSize)size;
- (void)startGameLoop;
- (void)showErrorMessage:(NSString*)message;

@end
