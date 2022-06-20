//
//  ios_wnd.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 10/06/2022.
//

#import "ios_wnd.h"
#import <UIKit/UIKit.h>

bool _allow_hidpi_window = true;

@implementation OTTD_CocoaWindow
@end

@implementation OTTD_CocoaView

- (CGRect)getRealRect:(CGRect)rect {
    return rect;
}

- (CGRect)getVirtualRect:(CGRect)rect {
    return rect;
}

- (CGFloat)getContentsScale {
    return 0;
}

bool CocoaSetupApplication() {
    return true;
}

void CocoaExitApplication() {
    
}

@end
