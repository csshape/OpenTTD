//
//  ios_wnd.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 10/06/2022.
//

#ifndef IOS_WND_H
#define IOS_WND_H

#import <UIKit/UIKit.h>

class VideoDriver_Cocoa;

extern NSString *OTTDMainLaunchGameEngine;

/** Subclass of NSWindow to cater our special needs */
@interface OTTD_CocoaWindow : UIWindow
@end

/** Subclass of NSView to support mouse awareness and text input. */
@interface OTTD_CocoaView : UIView

- (CGRect)getRealRect:(CGRect)rect;
- (CGRect)getVirtualRect:(CGRect)rect;
- (CGFloat)getContentsScale;
@end

extern bool _allow_hidpi_window;

bool CocoaSetupApplication();
void CocoaExitApplication();

#endif /* IOS_WND_H */
