//
//  UIScreen+Helper.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 28/05/2023.
//

#import "UIScreen+Helper.h"

@implementation UIScreen(Helper)

+ (UIScreen*)getScreen {
    if ([[UIScreen screens] count] > 1) {
        UIScreen *screen = [UIScreen screens][1];
        return screen;
    } else {
        return [UIScreen mainScreen];
    }
}

@end
