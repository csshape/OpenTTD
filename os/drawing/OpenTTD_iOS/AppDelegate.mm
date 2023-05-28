//
//  AppDelegate.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"

#include "stdafx.h"

#include "openttd.h"
#include "debug.h"

#include "ios_wnd.h"

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
#include <string>

#include "VideoDriver_OpenGLES.h"
#import "ViewController.h"

#ifdef _DEBUG
static uint32 _tEvent;
#endif

extern const char * OSErrorMessage;

uint32 _realtime_tick = 0;

static uint32 GetTick()
{
    return CFAbsoluteTimeGetCurrent() * 1000;
}

static void CheckPaletteAnim()
{
    if (_cur_palette.count_dirty != 0) {
        Blitter *blitter = BlitterFactory::GetCurrentBlitter();
        
        switch (blitter->UsePaletteAnimation()) {
            case Blitter::PALETTE_ANIMATION_VIDEO_BACKEND:
//                _cocoa_touch_driver->UpdatePalette(_cur_palette.first_dirty, _cur_palette.count_dirty);
                break;
                
            case Blitter::PALETTE_ANIMATION_BLITTER:
                blitter->PaletteAnimate(_cur_palette);
                break;
                
            case Blitter::PALETTE_ANIMATION_NONE:
                break;
                
            default:
                NOT_REACHED();
        }
        _cur_palette.count_dirty = 0;
    }
}

@interface AppDelegate ()
@property (strong, nonatomic) ViewController *viewController;
@property (strong, nonatomic) CADisplayLink *displayLink;
@property (strong, nonatomic) NSOperationQueue *queue;

@property (strong, nonatomic) UIWindow *externalWindow;
@property (strong, nonatomic) UIImageView *imageView;
@end

@implementation AppDelegate
{
    uint32 cur_ticks, last_cur_ticks, next_tick;
}

- (void)setFontSetting:(FreeTypeSubSetting*)setting toFont:(UIFont*)font scale:(CGFloat)scale {
    std::string settingFont = setting->font;
    char* c = const_cast<char*>(settingFont.c_str());
    std::strcpy(c, font.fontDescriptor.postscriptName.UTF8String);
    setting->aa = true;
    setting->size = (uint)(font.pointSize * scale);
}

- (void)overrideDefaultSettings {
    IConsoleSetSetting("hover_delay_ms", 0);
    IConsoleSetSetting("osk_activation", 3);
    _gui_zoom = ZOOM_LVL_OUT_4X;
    CGFloat fontScale = 1; //[UIScreen mainScreen].nativeScale;
    
    UIFont *smallFont = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    [self setFontSetting:&_freetype.small toFont:smallFont scale:fontScale];
    [self setFontSetting:&_freetype.medium toFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] scale:fontScale];
    [self setFontSetting:&_freetype.large toFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] scale:fontScale];
    [self setFontSetting:&_freetype.mono toFont:[UIFont fontWithName:@"Menlo-Bold" size:smallFont.pointSize] scale:fontScale];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[OTTD_CocoaWindow alloc] initWithFrame: [UIScreen getScreen].bounds];
    self.window.clipsToBounds = true;

    self.window.backgroundColor = [UIColor redColor];

    if (_cocoa_touch_driver) {
        UIWindow *window = _cocoa_touch_driver->window;
        self.viewController = (ViewController*)window.rootViewController;
        self.window.rootViewController = self.viewController;
    } else {
        self.window.rootViewController = [[UIViewController alloc] init];
    }

    [self.window makeKeyAndVisible];
    
    if (OSErrorMessage) {
        [self showErrorMessage:@(OSErrorMessage)];
    } else {
        [self overrideDefaultSettings];

        GfxInitPalettes();
        CheckPaletteAnim();

        [self startGameLoop];
    }
    
    [self.viewController updateLayer];

    [self setupScreenNotifications];

    return YES;
}

- (void)showErrorMessage:(NSString*)errorMessage {
    UIViewController *viewController = self.window.rootViewController;
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Fatal Error" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    viewController.view.userInteractionEnabled = NO;
    [viewController presentViewController:alertController animated:YES completion:nil];
}

- (void)startGameLoop {
    if (self.displayLink != nil) return;
    cur_ticks = GetTick();
    last_cur_ticks = cur_ticks;
    next_tick = cur_ticks + MILLISECONDS_PER_TICK;
    
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    self.queue = queue;
    
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    self.displayLink = displayLink;
}

- (void)stopGameLoop {
    [self.queue cancelAllOperations];
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)resizeGameView:(CGSize) size isLandscape:(BOOL)isLandscape {
    CGFloat scale = 1; //[UIScreen mainScreen].nativeScale;
    
    if (_cocoa_touch_driver) {
        _cocoa_touch_driver->isLandscape = isLandscape;
        _cocoa_touch_driver->ChangeResolution(size.width * scale, size.height * scale);
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [self stopGameLoop];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if (_settings_client.gui.autosave_on_exit && _game_mode != GM_MENU && _game_mode != GM_BOOTSTRAP) {
        DoExitSave();
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    if (OSErrorMessage == NULL) {
        [self startGameLoop];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    if (_game_mode != GM_MENU && _game_mode != GM_BOOTSTRAP) {
        DoExitSave();
    }
    _exit_game = true;
}

- (void)tick:(CADisplayLink*)link {
    uint32 prev_cur_ticks = cur_ticks;
    InteractiveRandom(); // randomness
    
    if (_exit_game) {
        [link invalidate];
        _cocoa_touch_driver->Stop();
    }
    
    if (_switch_mode != SM_NONE) {
        BOOL isLandscape = UIDeviceOrientationIsLandscape([UIDevice currentDevice].orientation);
        [self resizeGameView:self.window.bounds.size isLandscape:isLandscape];
    }
    
    cur_ticks = GetTick();
    if (cur_ticks >= next_tick || !_pause_mode || cur_ticks < prev_cur_ticks) {
        _realtime_tick += cur_ticks - last_cur_ticks;
        last_cur_ticks = cur_ticks;
        next_tick = cur_ticks + MILLISECONDS_PER_TICK;
        
        bool old_ctrl_pressed = _ctrl_pressed;
    
        if (old_ctrl_pressed != _ctrl_pressed) HandleCtrlChanged();
        
        GameLoop();
        _cocoa_touch_driver->OpenGLTick();

        if (self.externalWindow) {
            self.imageView.image = [self.viewController getImageFromView];
        }
    }
}

- (void)setupScreenNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(externalScreenDidConnect:) name:UIScreenDidConnectNotification object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(externalScreenDidDisconnect:) name:UIScreenDidDisconnectNotification object:nil];

}

-(void)externalScreenDidConnect:(NSNotification *)notification {
    UIScreen *screen = (UIScreen *)[notification object];
    if (screen != nil) {
        [self setupExternalScreen:screen];
    }
}

-(void)externalScreenDidDisconnect:(NSNotification *)notification {
    id obj = [notification object];
    if (obj != nil) {
        [self teardownExternalScreen];
    }
}

-(void)setupExternalScreen:(UIScreen *)screen {
    UIViewController *viewController = [UIViewController new];

    self.externalWindow = [[OTTD_CocoaWindow alloc] initWithFrame:screen.bounds];
    self.externalWindow.rootViewController = viewController;
    self.externalWindow.screen = screen;
    self.externalWindow.hidden = false;

    [self.externalWindow makeKeyAndVisible];

    UIImageView *view = [UIImageView new];
    view.frame = screen.bounds;
    view.backgroundColor = [UIColor darkGrayColor];
//    view.contentMode = UIViewContentModeScaleAspectFit;
    [viewController.view addSubview:view];

    [self.viewController setDarkScreen:YES];

    self.imageView = view;
}

-(void)teardownExternalScreen {
    if (self.externalWindow != nil) {
        self.externalWindow.hidden = true;
        self.externalWindow = nil;
    }

    [self.viewController setDarkScreen:NO];
}

@end
