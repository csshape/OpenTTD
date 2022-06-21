//
//  AppDelegate.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 03/06/2022.
//

#import "AppDelegate.h"

#include "stdafx.h"
#include "gfx_layout.h"
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
@end

@implementation AppDelegate
{
    NSTimer *gameLoopTimer;
    uint32 cur_ticks, last_cur_ticks, next_tick;
}

+ (AppDelegate *)sharedInstance {
    static AppDelegate *appDelegate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appDelegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    });
    return appDelegate;
}

- (void)setFontSetting:(FreeTypeSubSetting*)setting toFont:(UIFont*)font scale:(CGFloat)scale {
//    strcpy(setting->font, font.fontDescriptor.postscriptName.UTF8String);
    setting->aa = true;
    setting->size = (uint)(font.pointSize * scale);
}

- (void)overrideDefaultSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    IConsoleSetSetting("hover_delay_ms", 0);
    IConsoleSetSetting("osk_activation", 3);
    BOOL hiDPI = [defaults boolForKey:@"NativeResolution"];
//    _gui_zoom = hiDPI ? 1 : 2;
    CGFloat fontScale = hiDPI ? [UIScreen mainScreen].nativeScale : 1.0;
    
    UIFont *smallFont = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    [self setFontSetting:&_freetype.small toFont:smallFont scale:fontScale];
    [self setFontSetting:&_freetype.medium toFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote] scale:fontScale];
    [self setFontSetting:&_freetype.large toFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody] scale:fontScale];
    [self setFontSetting:&_freetype.mono toFont:[UIFont fontWithName:@"Menlo-Bold" size:smallFont.pointSize] scale:fontScale];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[OTTD_CocoaWindow alloc] initWithFrame: [UIScreen mainScreen].bounds];
    self.window.clipsToBounds = true;
    
    self.window.backgroundColor = [UIColor redColor];
    
    UIWindow *win = _cocoa_touch_driver->window;

    self.viewController = (ViewController*)win.rootViewController;
    
    self.window.rootViewController = self.viewController;
    
    [self.window makeKeyAndVisible];
    
    if (OSErrorMessage) {
        [self showErrorMessage:@(OSErrorMessage)];
    } else {
        [self overrideDefaultSettings];

        GfxInitPalettes();
        CheckPaletteAnim();
        _cocoa_touch_driver->Draw();

        [self startGameLoop];
    }
    
    [self.viewController updateLayer];
    
    return YES;
}

- (void)showErrorMessage:(NSString*)errorMessage {
    UIViewController *viewController = self.window.rootViewController;
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Fatal Error" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
    viewController.view.userInteractionEnabled = NO;
    [viewController presentViewController:alertController animated:YES completion:nil];
}

- (void)startGameLoop {
    if (gameLoopTimer.valid) return;
    cur_ticks = GetTick();
    last_cur_ticks = cur_ticks;
    next_tick = cur_ticks + MILLISECONDS_PER_TICK;
    
    _cocoa_touch_driver->OpenGLStartGame();
    
    NSTimeInterval gameLoopInterval = 1.0 / 60.0;
    gameLoopTimer = [NSTimer scheduledTimerWithTimeInterval:gameLoopInterval target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)stopGameLoop {
    [gameLoopTimer invalidate];
    
    _cocoa_touch_driver->OpenGLStopGame();
}

- (void)resizeGameView:(CGSize)size {
    CGFloat scale = [[NSUserDefaults standardUserDefaults] boolForKey:@"NativeResolution"] ? [UIScreen mainScreen].nativeScale : 1.0;
//    _resolutions[0].width = size.width * scale;
//    _resolutions[0].height = size.height * scale;
    if (_cocoa_touch_driver) {
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

- (void)tick:(NSTimer*)timer {
    uint32 prev_cur_ticks = cur_ticks; // to check for wrapping
    InteractiveRandom(); // randomness
    
    if (_exit_game) {
        [timer invalidate];
//        _cocoa_touch_driver->ExitMainLoop();
    }
    
    cur_ticks = GetTick();
    if (cur_ticks >= next_tick || cur_ticks < prev_cur_ticks) {
        _realtime_tick += cur_ticks - last_cur_ticks;
        last_cur_ticks = cur_ticks;
        next_tick = cur_ticks + MILLISECONDS_PER_TICK;
        
        bool old_ctrl_pressed = _ctrl_pressed;
        
        //_ctrl_pressed = !!(_current_mods & ( _settings_client.gui.right_mouse_btn_emulation != RMBE_CONTROL ? NSControlKeyMask : NSCommandKeyMask));
        //_shift_pressed = !!(_current_mods & NSShiftKeyMask);
        
        if (old_ctrl_pressed != _ctrl_pressed) HandleCtrlChanged();
        
        _cocoa_touch_driver->OpenGLTick();
    }
}

@end
