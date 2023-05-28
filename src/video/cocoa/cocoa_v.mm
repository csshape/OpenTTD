/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_v.mm Code related to the cocoa video driver(s). */

/******************************************************************************
 *                             Cocoa video driver                             *
 * Known things left to do:                                                   *
 *  Nothing at the moment.                                                    *
 ******************************************************************************/

#if defined(WITH_COCOA) || defined(IOS)

#include "../../stdafx.h"

#if !defined(IOS)
#include "../../os/macosx/macos.h"
#endif

#define Rect  OTTDRect
#define Point OTTDPoint

#if defined(IOS)
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#endif

#undef Rect
#undef Point

#include "../../openttd.h"
#include "../../debug.h"
#include "../../core/geometry_func.hpp"
#include "../../core/math_func.hpp"
#include "cocoa_v.h"

#if defined(IOS)
#include "ios_wnd.h"
#else
#include "cocoa_wnd.h"
#endif

#include "../../blitter/factory.hpp"
#include "../../framerate_type.h"
#include "../../gfx_func.h"
#include "../../thread.h"
#include "../../core/random_func.hpp"
#include "../../progress.h"
#include "../../settings_type.h"
#include "../../window_func.h"
#include "../../window_gui.h"

#import <sys/param.h> /* for MAXPATHLEN */
#import <sys/time.h> /* gettimeofday */
#include <array>

#import "ViewController.h"
#import "AppDelegate.h"

/* The 10.12 SDK added new names for some enum constants and
 * deprecated the old ones. As there's no functional change in any
 * way, just use a define for older SDKs to the old names. */
#ifndef HAVE_OSX_1012_SDK
#	define NSEventModifierFlagCommand NSCommandKeyMask
#	define NSEventModifierFlagControl NSControlKeyMask
#	define NSEventModifierFlagOption NSAlternateKeyMask
#	define NSEventModifierFlagShift NSShiftKeyMask
#	define NSEventModifierFlagCapsLock NSAlphaShiftKeyMask
#endif

/**
 * Important notice regarding all modifications!!!!!!!
 * There are certain limitations because the file is objective C++.
 * gdb has limitations.
 * C++ and objective C code can't be joined in all cases (classes stuff).
 * Read http://developer.apple.com/releasenotes/Cocoa/Objective-C++.html for more information.
 */

/* On some old versions of MAC OS this may not be defined.
 * Those versions generally only produce code for PPC. So it should be safe to
 * set this to 0. */
#ifndef kCGBitmapByteOrder32Host
#define kCGBitmapByteOrder32Host 0
#endif

extern "C" {
    extern char ***_NSGetArgv(void);
    extern int *_NSGetArgc(void);
}

bool _cocoa_video_started = false;

extern bool _tab_is_down;


/** List of common display/window sizes. */
static const Dimension _default_resolutions[] = {
	{  640,  480 },
	{  800,  600 },
	{ 1024,  768 },
	{ 1152,  864 },
	{ 1280,  800 },
	{ 1280,  960 },
	{ 1280, 1024 },
	{ 1400, 1050 },
	{ 1600, 1200 },
	{ 1680, 1050 },
	{ 1920, 1200 },
	{ 2560, 1440 }
};


VideoDriver_Cocoa::VideoDriver_Cocoa()
{
	this->setup         = false;
	this->buffer_locked = false;

	this->refresh_sys_sprites = true;

	this->window    = nil;
	this->cocoaview = nil;
	this->delegate  = nil;

	this->color_space = nullptr;

	this->dirty_rect = {};
}

/** Stop Cocoa video driver. */
void VideoDriver_Cocoa::Stop()
{
	if (!_cocoa_video_started) return;

	CocoaExitApplication();

	/* Release window mode resources */
#if !defined(IOS)
	if (this->window != nil) [ this->window close ];
#endif
//	[ this->cocoaview release ];
//	[ this->delegate release ];

	CGColorSpaceRelease(this->color_space);

	_cocoa_video_started = false;
}

/** Common driver initialization. */
const char *VideoDriver_Cocoa::Initialize()
{
#if !defined(IOS)
	if (!MacOSVersionIsAtLeast(10, 7, 0)) return "The Cocoa video driver requires Mac OS X 10.7 or later.";
#endif
    
	if (_cocoa_video_started) return "Already started";
	_cocoa_video_started = true;

	/* Don't create a window or enter fullscreen if we're just going to show a dialog. */
	if (!CocoaSetupApplication()) return nullptr;

	this->UpdateAutoResolution();
	this->orig_res = _cur_resolution;

	return nullptr;
}

/**
 * Set dirty a rectangle managed by a cocoa video subdriver.
 * @param left Left x cooordinate of the dirty rectangle.
 * @param top Uppder y coordinate of the dirty rectangle.
 * @param width Width of the dirty rectangle.
 * @param height Height of the dirty rectangle.
 */
void VideoDriver_Cocoa::MakeDirty(int left, int top, int width, int height)
{
	Rect r = {left, top, left + width, top + height};
	this->dirty_rect = BoundingRect(this->dirty_rect, r);
}

/**
 * Start the main programme loop when using a cocoa video driver.
 */
void VideoDriver_Cocoa::MainLoop()
{
#if defined(IOS)
    if (setjmp(main_loop_jmp) == 0) {
        UIApplication *app = [UIApplication sharedApplication];
        if (app == nil) {
            NSString * appDelegateClassName;
            @autoreleasepool {
                // Setup code that might create autoreleased objects goes here.
                appDelegateClassName = NSStringFromClass([AppDelegate class]);
            }
            UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, appDelegateClassName);
        } else {
            // this only happens after bootstrap
            [app.delegate performSelector:@selector(startGameLoop)];
            [[NSRunLoop mainRunLoop] run];
        }
    }
#else
    /* Restart game loop if it was already running (e.g. after bootstrapping),
     * otherwise this call is a no-op. */
    [ [ NSNotificationCenter defaultCenter ] postNotificationName:OTTDMainLaunchGameEngine object:nil ];

    /* Start the main event loop. */
    [ NSApp run ];
#endif
}

/**
 * Change the resolution when using a cocoa video driver.
 * @param w New window width.
 * @param h New window height.
 * @return Whether the video driver was successfully updated.
 */
bool VideoDriver_Cocoa::ChangeResolution(int w, int h)
{
#if defined(IOS)
    CGRect contentRect = CGRectMake(0, 0, w, h);
    
    if (this->cocoaview != nil) {
        [this->cocoaview setFrame:contentRect];
    }
#else
	NSSize screen_size = [ [ NSScreen mainScreen ] frame ].size;
	w = std::min(w, (int)screen_size.width);
	h = std::min(h, (int)screen_size.height);

	NSRect contentRect = NSMakeRect(0, 0, w, h);
	[ this->window setContentSize:contentRect.size ];

	/* Ensure frame height - title bar height >= view height */
	float content_height = [ this->window contentRectForFrameRect:[ this->window frame ] ].size.height;
	contentRect.size.height = Clamp(h, 0, (int)content_height);

	if (this->cocoaview != nil) {
		h = (int)contentRect.size.height;
		[ this->cocoaview setFrameSize:contentRect.size ];
	}

	[ (OTTD_CocoaWindow *)this->window center ];
#endif
    
	this->AllocateBackingStore();

	return true;
}

/**
 * Toggle between windowed and full screen mode for cocoa display driver.
 * @param full_screen Whether to switch to full screen or not.
 * @return Whether the mode switch was successful.
 */
bool VideoDriver_Cocoa::ToggleFullscreen(bool full_screen)
{
#if defined(IOS)
    return false;
#else
	if (this->IsFullscreen() == full_screen) return true;

	if ([ this->window respondsToSelector:@selector(toggleFullScreen:) ]) {
		[ this->window performSelector:@selector(toggleFullScreen:) withObject:this->window ];

		/* Hide the menu bar and the dock */
		[ NSMenu setMenuBarVisible:!full_screen ];

		this->UpdateVideoModes();
		InvalidateWindowClassesData(WC_GAME_OPTIONS, 3);
		return true;
	}

	return false;
#endif
}

void VideoDriver_Cocoa::ClearSystemSprites()
{
	this->refresh_sys_sprites = true;
}

void VideoDriver_Cocoa::PopulateSystemSprites()
{
#if !defined(IOS)
	if (this->refresh_sys_sprites && this->window != nil) {
		[ this->window refreshSystemSprites ];
		this->refresh_sys_sprites = false;
	}
#endif
}

/**
 * Callback invoked after the blitter was changed.
 * @return True if no error.
 */
bool VideoDriver_Cocoa::AfterBlitterChange()
{
	this->AllocateBackingStore(true);
	return true;
}

/**
 * An edit box lost the input focus. Abort character compositing if necessary.
 */
void VideoDriver_Cocoa::EditBoxLostFocus()
{
#if !defined(IOS)
	[ [ this->cocoaview inputContext ] performSelectorOnMainThread:@selector(discardMarkedText) withObject:nil waitUntilDone:[ NSThread isMainThread ] ];
	/* Clear any marked string from the current edit box. */
	HandleTextInput(nullptr, true);
#endif
}

/**
 * Get refresh rates of all connected monitors.
 */
std::vector<int> VideoDriver_Cocoa::GetListOfMonitorRefreshRates()
{
	std::vector<int> rates{};

#if defined(IOS)
    rates.push_back(1);
#else
	if (MacOSVersionIsAtLeast(10, 6, 0)) {
		std::array<CGDirectDisplayID, 16> displays;

		uint32_t count = 0;
		CGGetActiveDisplayList(displays.size(), displays.data(), &count);

		for (uint32_t i = 0; i < count; i++) {
			CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displays[i]);
			int rate = (int)CGDisplayModeGetRefreshRate(mode);
			if (rate > 0) rates.push_back(rate);
			CGDisplayModeRelease(mode);
		}
	}
#endif

	return rates;
}

/**
 * Get the resolution of the main screen.
 */
Dimension VideoDriver_Cocoa::GetScreenSize() const
{
#if defined(IOS)
    UIScreen *screen = [UIScreen getScreen];
    CGRect frame = [screen bounds];
    return { static_cast<uint>(frame.size.width), static_cast<uint>(frame.size.height) };
#else
    NSRect frame = [ [ NSScreen mainScreen ] frame ];
    return { static_cast<uint>(NSWidth(frame)), static_cast<uint>(NSHeight(frame)) };
#endif
}

/** Get DPI scale of our window. */
float VideoDriver_Cocoa::GetDPIScale()
{
	return this->cocoaview != nil ? [ this->cocoaview getContentsScale ] : 1.0f;
}

/** Lock video buffer for drawing if it isn't already mapped. */
bool VideoDriver_Cocoa::LockVideoBuffer()
{
	if (this->buffer_locked) return false;
	this->buffer_locked = true;

	_screen.dst_ptr = this->GetVideoPointer();
	assert(_screen.dst_ptr != nullptr);

	return true;
}

/** Unlock video buffer. */
void VideoDriver_Cocoa::UnlockVideoBuffer()
{
	if (_screen.dst_ptr != nullptr) {
		/* Hand video buffer back to the drawing backend. */
		this->ReleaseVideoPointer();
		_screen.dst_ptr = nullptr;
	}

	this->buffer_locked = false;
}

/**
 * Are we in fullscreen mode?
 * @return whether fullscreen mode is currently used
 */
bool VideoDriver_Cocoa::IsFullscreen()
{
#if defined(IOS)
    return true;
#else
	return this->window != nil && ([ this->window styleMask ] & NSWindowStyleMaskFullScreen) != 0;
#endif
}

/**
 * Handle a change of the display area.
 */
void VideoDriver_Cocoa::GameSizeChanged()
{
	/* Store old window size if we entered fullscreen mode. */
	bool fullscreen = this->IsFullscreen();
	if (fullscreen && !_fullscreen) this->orig_res = _cur_resolution;
	_fullscreen = fullscreen;

	BlitterFactory::GetCurrentBlitter()->PostResize();

	::GameSizeChanged();

	/* We need to store the window size as non-Retina size in
	* the config file to get same windows size on next start. */
	_cur_resolution.width = [ this->cocoaview frame ].size.width;
	_cur_resolution.height = [ this->cocoaview frame ].size.height;
}

/**
 * Update the video mode.
 */
void VideoDriver_Cocoa::UpdateVideoModes()
{
	_resolutions.clear();

#if defined(IOS)
    UIScreen *screen = [UIScreen getScreen];
    CGSize maxSize = [screen bounds].size;
    for (const auto &d : _default_resolutions) {
        if (d.width < maxSize.width && d.height < maxSize.height) _resolutions.push_back(d);
    }
    _resolutions.emplace_back((uint)maxSize.width, (uint)maxSize.height);
#else
    if (this->IsFullscreen()) {
        /* Full screen, there is only one possible resolution. */
        NSSize screen = [ [ this->window screen ] frame ].size;
        _resolutions.emplace_back((uint)screen.width, (uint)screen.height);
    } else {
        /* Windowed; offer a selection of common window sizes up until the
         * maximum usable screen space. This excludes the menu and dock areas. */
        NSSize maxSize = [ [ NSScreen mainScreen] visibleFrame ].size;
        for (const auto &d : _default_resolutions) {
            if (d.width < maxSize.width && d.height < maxSize.height) _resolutions.push_back(d);
        }
        _resolutions.emplace_back((uint)maxSize.width, (uint)maxSize.height);
    }
#endif
}

/**
 * Build window and view with a given size.
 * @param width Window width.
 * @param height Window height.
 */
bool VideoDriver_Cocoa::MakeWindow(int width, int height)
{
	this->setup = true;
#if defined(IOS)
    UIScreen *screen = [UIScreen getScreen];
    this->window = [[OTTD_CocoaWindow alloc] initWithFrame:screen.bounds];
    this->window.screen = screen;
    this->window.hidden = false;

    CGRect view_frame = [this->window bounds];
    OTTD_CocoaView *cocoaview = [ [OTTD_CocoaView alloc] initWithFrame:view_frame];
    this->cocoaview = cocoaview;

    UIView *draw_view = this->AllocateDrawView();

    ViewController *viewController = [[ViewController alloc] init];
    viewController.view.frame = this->window.bounds;
    this->window.rootViewController = viewController;

    viewController.cocoaView = cocoaview;
    [cocoaview addSubview:draw_view];

    cocoaview.translatesAutoresizingMaskIntoConstraints = false;
    draw_view.translatesAutoresizingMaskIntoConstraints = false;

    NSDictionary *views = NSDictionaryOfVariableBindings(cocoaview, draw_view);
    [viewController.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[cocoaview]-0-|" options:0 metrics:nil views:views]];
    [viewController.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[cocoaview]-0-|" options:0 metrics:nil views:views]];
    [cocoaview addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[draw_view]-0-|" options:0 metrics:nil views:views]];
    [cocoaview addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[draw_view]-0-|" options:0 metrics:nil views:views]];
#else
	/* Limit window size to screen frame. */
	NSSize screen_size = [ [ NSScreen mainScreen ] frame ].size;
	if (width > screen_size.width) width = screen_size.width;
	if (height > screen_size.height) height = screen_size.height;

	NSRect contentRect = NSMakeRect(0, 0, width, height);

	/* Create main window. */
#ifdef HAVE_OSX_1012_SDK
	unsigned int style = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskClosable;
#else
	unsigned int style = NSTitledWindowMask | NSResizableWindowMask | NSMiniaturizableWindowMask | NSClosableWindowMask;
#endif
	this->window = [ [ OTTD_CocoaWindow alloc ] initWithContentRect:contentRect styleMask:style backing:NSBackingStoreBuffered defer:NO driver:this ];
	if (this->window == nil) {
		Debug(driver, 0, "Could not create the Cocoa window.");
		this->setup = false;
		return false;
	}

	/* Add built in full-screen support when available (OS X 10.7 and higher)
	 * This code actually compiles for 10.5 and later, but only makes sense in conjunction
	 * with the quartz fullscreen support as found only in 10.7 and later. */
	if ([ this->window respondsToSelector:@selector(toggleFullScreen:) ]) {
		NSWindowCollectionBehavior behavior = [ this->window collectionBehavior ];
		behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
		[ this->window setCollectionBehavior:behavior ];

		NSButton* fullscreenButton = [ this->window standardWindowButton:NSWindowZoomButton ];
		[ fullscreenButton setAction:@selector(toggleFullScreen:) ];
		[ fullscreenButton setTarget:this->window ];
	}

	this->delegate = [ [ OTTD_CocoaWindowDelegate alloc ] initWithDriver:this ];
	[ this->window setDelegate:this->delegate ];

	[ this->window center ];
	[ this->window makeKeyAndOrderFront:nil ];

	/* Create wrapper view for input and event handling. */
	NSRect view_frame = [ this->window contentRectForFrameRect:[ this->window frame ] ];
	this->cocoaview = [ [ OTTD_CocoaView alloc ] initWithFrame:view_frame ];
	if (this->cocoaview == nil) {
		Debug(driver, 0, "Could not create the event wrapper view.");
		this->setup = false;
		return false;
	}
	[ this->cocoaview setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable ];

	/* Create content view. */
	NSView *draw_view = this->AllocateDrawView();
	if (draw_view == nil) {
		Debug(driver, 0, "Could not create the drawing view.");
		this->setup = false;
		return false;
	}
	[ draw_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable ];

	/* Create view chain: window -> input wrapper view -> content view. */
	[ this->window setContentView:this->cocoaview ];
	[ this->cocoaview addSubview:draw_view ];
	[ this->window makeFirstResponder:this->cocoaview ];
//	[ draw_view release ];

	[ this->window setColorSpace:[ NSColorSpace sRGBColorSpace ] ];
	CGColorSpaceRelease(this->color_space);
	this->color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	if (this->color_space == nullptr) this->color_space = CGColorSpaceCreateDeviceRGB();
	if (this->color_space == nullptr) error("Could not get a valid colour space for drawing.");
#endif
	this->setup = false;

	return true;
}


/**
 * Poll and handle a single event from the OS.
 * @return True if there was an event to handle.
 */
bool VideoDriver_Cocoa::PollEvent()
{
#if defined(IOS)
    return false;
#else
#ifdef HAVE_OSX_1012_SDK
	NSEventMask mask = NSEventMaskAny;
#else
	NSEventMask mask = NSAnyEventMask;
#endif
	NSEvent *event = [ NSApp nextEventMatchingMask:mask untilDate:[ NSDate distantPast ] inMode:NSDefaultRunLoopMode dequeue:YES ];

	if (event == nil) return false;

	[ NSApp sendEvent:event ];

	return true;
#endif
}

void VideoDriver_Cocoa::InputLoop()
{
#if !defined(IOS)
	NSUInteger cur_mods = [ NSEvent modifierFlags ];

	bool old_ctrl_pressed = _ctrl_pressed;

	_ctrl_pressed = (cur_mods & ( _settings_client.gui.right_mouse_btn_emulation != RMBE_CONTROL ? NSEventModifierFlagControl : NSEventModifierFlagCommand)) != 0;
	_shift_pressed = (cur_mods & NSEventModifierFlagShift) != 0;

#if defined(_DEBUG)
	this->fast_forward_key_pressed = _shift_pressed;
#else
	this->fast_forward_key_pressed = _tab_is_down;
#endif

	if (old_ctrl_pressed != _ctrl_pressed) HandleCtrlChanged();
#endif
}

/** Main game loop. */
void VideoDriver_Cocoa::MainLoopReal()
{
	this->StartGameThread();

	for (;;) {
		@autoreleasepool {
			if (_exit_game) {
				/* Restore saved resolution if in fullscreen mode. */
				if (this->IsFullscreen()) _cur_resolution = this->orig_res;
				break;
			}

			this->Tick();
			this->SleepTillNextTick();
		}
	}

	this->StopGameThread();
}

#endif /* WITH_COCOA */
