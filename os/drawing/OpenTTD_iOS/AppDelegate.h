//
//  AppDelegate.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#if defined (IOS)
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (strong, nonatomic) UIWindow *window;

- (void)resizeGameView:(CGSize)size isLandscape:(BOOL)isLandscape;
- (void)startGameLoop;
- (void)showErrorMessage:(NSString*)message;

@end
#endif
