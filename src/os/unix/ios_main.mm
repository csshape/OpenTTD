/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_main.mm iOS app bootstrap for SDL2-free builds. */

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#include "../../stdafx.h"

#include "../../debug.h"
#include "../../openttd.h"
#include "ios_main.h"

#include <thread>

static std::vector<std::string> _ios_params_storage;
static std::vector<std::string_view> _ios_params;

@interface OTTD_iOSAppDelegate : UIResponder <UIApplicationDelegate> {
@private
	UIWindow *_window;
}
@end

@implementation OTTD_iOSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	(void)application;
	(void)launchOptions;

	AVAudioSession *audio_session = [AVAudioSession sharedInstance];
	NSError *audio_error = nil;
	if (![audio_session setCategory:AVAudioSessionCategoryAmbient error:&audio_error]) {
		Debug(driver, 0, "ios_main: Failed to configure AVAudioSession category: {}", [[audio_error localizedDescription] UTF8String]);
	}

	audio_error = nil;
	if (![audio_session setActive:YES error:&audio_error]) {
		Debug(driver, 0, "ios_main: Failed to activate AVAudioSession: {}", [[audio_error localizedDescription] UTF8String]);
	}

	_window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	_window.rootViewController = [[[UIViewController alloc] init] autorelease];
	[_window makeKeyAndVisible];

	std::thread engine_thread([] {
		@autoreleasepool {
			int ret = openttd_main(_ios_params);
			exit(ret);
		}
	});
	engine_thread.detach();

	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	(void)application;
	_exit_game = true;
}

- (void)dealloc
{
	[_window release];
	[super dealloc];
}

@end

int IOSRunMain(const std::vector<std::string_view> &params)
{
	_ios_params_storage.clear();
	_ios_params_storage.reserve(params.size());
	_ios_params.clear();
	_ios_params.reserve(params.size());

	for (const std::string_view &param : params) {
		_ios_params_storage.emplace_back(param);
	}
	for (const std::string &param : _ios_params_storage) {
		_ios_params.emplace_back(param);
	}
	if (_ios_params.empty()) {
		_ios_params_storage.emplace_back("openttd");
		_ios_params.emplace_back(_ios_params_storage.back());
	}

	@autoreleasepool {
		int argc = 1;
		char arg0[] = "openttd";
		char *argv[] = { arg0, nullptr };
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([OTTD_iOSAppDelegate class]));
	}
}
