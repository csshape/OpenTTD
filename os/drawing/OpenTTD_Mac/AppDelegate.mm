//
//  AppDelegate.m
//  OpenTTD_Mac
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"

#include "openttd.h"
#include "debug.h"

#include "script_types.hpp"
#include "cocoa_v.h"
#include "factory.hpp"
#include "gfx_func.h"
#include "random_func.hpp"
#include "network.h"
#include "saveload.h"
#include "settings_type.h"
#include "settings_func.h"
#include "fontcache.h"
#include "window_func.h"
#include "window_gui.h"

@interface AppDelegate ()


@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Insert code here to initialize your application
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}


- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}


@end
