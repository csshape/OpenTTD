//
//  GameInputView.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 21/06/2022.
//

#import "GameInputView.h"
#import "AppDelegate.h"
#include "stdafx.h"
#include "openttd.h"
#include "debug.h"
#include "cocoa_v.h"
#include "gfx_func.h"
#include "querystring_gui.h"
#include "smallmap_gui.h"
#include "textbuf_gui.h"
#include "tilehighlight_func.h"
#include "window_func.h"
#include "window_gui.h"
#include "zoom_func.h"

/* Table data for key mapping. */
#include "ios_keys.h"

extern CALayer *_cocoa_touch_layer;
static GameInputView *_cocoa_input_view;

std::string _keyboard_opt[2];
static WChar _keyboard[2][OSK_KEYBOARD_ENTRIES];

/* Right Mouse Button Emulation enum */
enum RightMouseButtonEmulationState {
    RMBE_COMMAND = 0,
    RMBE_CONTROL = 1,
    RMBE_OFF     = 2,
};

void ShowOnScreenKeyboard(Window *parent, int button) {
    [_cocoa_input_view becomeFirstResponder];
}

void HideOnScreenKeyboard() {
    if ([_cocoa_input_view isFirstResponder]) {
        [_cocoa_input_view resignFirstResponder];
    }
}

void UpdateOSKOriginalText(const Window *parent, int button) {
    
}

bool IsOSKOpenedFor(const Window *w, int button) {
    if (_focused_window == w && [_cocoa_input_view isFirstResponder]) {
        return true;
    }
    return false;
}

@implementation GameInputView
{
    int start_scrollpos_x, start_scrollpos_y;
    CGFloat wheelLevel;
    Window *panWindow;
    CGRect keyboardFrame;
    NSTimer *keyTimer;
    NSMutableArray *keys;
    
    BOOL _tab_is_down;
}

- (void)startUp {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self selector:@selector(ensureInputFieldIsVisible:) name:UIKeyboardWillChangeFrameNotification object:nil];
    
    UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    panRecognizer.minimumNumberOfTouches = 2;
    [self addGestureRecognizer:panRecognizer];
    
    UIPinchGestureRecognizer *pinchRecognizer = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
    [self addGestureRecognizer:pinchRecognizer];
    
    _cocoa_input_view = self;
    keyboardFrame = CGRectZero;
}

- (void)handlePanGesture:(UIPanGestureRecognizer*)recognizer {
    Point point;
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            point = [self gamePoint:[recognizer locationInView:self]];
            panWindow = FindWindowFromPt(point.x, point.y);
            if (panWindow->viewport) {
                // viewport
                start_scrollpos_x = panWindow->viewport->dest_scrollpos_x;
                start_scrollpos_y = panWindow->viewport->dest_scrollpos_y;
            } else if (panWindow->window_class == WC_SMALLMAP) {
                // smallmap
                point = [self gamePoint:[recognizer translationInView:self]];
                start_scrollpos_x = point.x;
                start_scrollpos_y = point.y;
                break;
            } else {
                // mouse wheel
                _cursor.UpdateCursorPosition(point.x, point.y, false);
                _left_button_down = false;
                _left_button_clicked = false;
                wheelLevel = 0.0;
            }
        case UIGestureRecognizerStateChanged:
            point = [self gamePoint:[recognizer translationInView:self]];
            if (panWindow->viewport && _game_mode != GM_MENU) {
                // viewport
                int x = -point.x;
                int y = -point.y;
                panWindow->viewport->dest_scrollpos_x = start_scrollpos_x + ScaleByZoom(x, panWindow->viewport->zoom);
                panWindow->viewport->dest_scrollpos_y = start_scrollpos_y + ScaleByZoom(y, panWindow->viewport->zoom);
            } else if (panWindow->window_class == WC_SMALLMAP) {
                // smallmap
                SmallMapWindow *w = (SmallMapWindow*)panWindow;
                Point scrollPoint = { .x = start_scrollpos_x - point.x, .y = start_scrollpos_y - point.y };
                w->OnScroll(scrollPoint);
                start_scrollpos_x = point.x;
                start_scrollpos_y = point.y;
            } else if (panWindow->viewport == NULL) {
                // mouse wheel
                int increment = (wheelLevel - point.y) / (5 * (4 >> _gui_zoom));
                [self handleMouseWheelEvent:increment];
                wheelLevel = point.y;
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            panWindow = NULL;
            _cursor.fix_at = false;
            HandleMouseEvents();
        default:
            break;
    }
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer*)recognizer {
    Point point = [self gamePoint:[recognizer locationInView:self]];

    switch (recognizer.state) {
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            wheelLevel = 0.0;
            break;
        case UIGestureRecognizerStateBegan:
            _cursor.UpdateCursorPosition(point.x, point.y, false);
            _left_button_down = false;
            _left_button_clicked = false;
            wheelLevel = recognizer.scale;
            break;
        case UIGestureRecognizerStateChanged:
            if (fabs(recognizer.scale - wheelLevel) > 0.25) {
                int increment = recognizer.scale < wheelLevel ? 1 : -1;
                [self handleMouseWheelEvent:increment];
                wheelLevel = recognizer.scale;
            }
        default:
            break;
    }
}

- (void)handleMouseWheelEvent:(int)increment {
    _cursor.wheel += increment;
    HandleMouseEvents();
}

- (Point)gamePoint:(CGPoint)point {
    CGSize size = self.bounds.size;
    Point gamePoint = {
        .x = (int)(point.x * (_screen.width / size.width)),
        .y = (int)(point.y * (_screen.height / size.height))
    };
    return gamePoint;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count == 1) {
        UITouch *touch = touches.anyObject;
        Point point = [self gamePoint:[touch locationInView:self]];
        _cursor.UpdateCursorPosition(point.x, point.y, false);
        _left_button_down = true;
        HandleMouseEvents();
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_left_button_down) {
        UITouch *touch = touches.anyObject;
        Point point = [self gamePoint:[touch locationInView:self]];
        _cursor.UpdateCursorPosition(point.x, point.y, false);
        _left_button_down = true;
        HandleMouseEvents();
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_left_button_down) {
        UITouch *touch = touches.anyObject;
        Point point = [self gamePoint:[touch locationInView:self]];
        _cursor.UpdateCursorPosition(point.x, point.y, false);
        _left_button_down = false;
        _left_button_clicked = false;
        HandleMouseEvents();
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_left_button_down) {
        ResetObjectToPlace();
        UITouch *touch = touches.anyObject;
        Point point = [self gamePoint:[touch locationInView:self]];
        _cursor.UpdateCursorPosition(point.x, point.y, false);
        _left_button_down = false;
        _left_button_clicked = false;
        HandleMouseEvents();
    }
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        CloseAllNonVitalWindows();
    }
}

- (void)ensureInputFieldIsVisible:(NSNotification*)notification {
    if ([notification.userInfo[UIKeyboardFrameEndUserInfoKey] isKindOfClass:[NSValue class]]) {
        keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    }
    
    if (!CGRectIntersectsRect(keyboardFrame, self.bounds) ||
        !EditBoxInGlobalFocus() ||
        _focused_window->window_class == WC_CONSOLE) {
        return;
    }
    
    CGAffineTransform transform = CGAffineTransformMakeScale(_screen.width / self.bounds.size.width, _screen.height / self.bounds.size.height);
    CGRect keyboardRect = CGRectApplyAffineTransform(keyboardFrame, transform);
    
    const NWidgetCore *widget = _focused_window->nested_focus;
    CGRect fieldRect = CGRectMake(_focused_window->left + widget->pos_x, _focused_window->top + widget->pos_y, widget->current_x, widget->current_y);
    if (CGRectIntersectsRect(fieldRect, keyboardRect)) {
        // see if offsetting the window upwards will fix it
        CGFloat offset = (_focused_window->top + widget->pos_y) - (keyboardRect.origin.y - widget->current_y);
        if (!CGRectIntersectsRect(CGRectOffset(fieldRect, 0, -offset), keyboardRect)) {
            _focused_window->top -= offset;
            MarkWholeScreenDirty();
        }
    }
}

#pragma mark - Key Input

- (BOOL)canBecomeFirstResponder {
    return EditBoxInGlobalFocus();
}

- (UIKeyboardType)keyboardType {
    if (EditBoxInGlobalFocus()) {
        if (_focused_window->window_class == WC_CONSOLE) {
            return UIKeyboardTypeASCIICapable;
        } else {
            const QueryString *qs = _focused_window->GetQueryString(_focused_window->nested_focus->index);
            switch (qs->text.afilter) {
                case CS_NUMERAL:
                    return UIKeyboardTypeDecimalPad;
                case CS_ALPHA:
                    return UIKeyboardTypeAlphabet;
                case CS_NUMERAL_SPACE:
                    return UIKeyboardTypeNumbersAndPunctuation;
                default:
                    return UIKeyboardTypeASCIICapable;
            }
        }
    }
    return UIKeyboardTypeASCIICapable;
}

- (BOOL)resignFirstResponder {
    [super resignFirstResponder];
    if (EditBoxInGlobalFocus()) {
        _focused_window->UnfocusFocusedWidget();
    }
    return YES;
}

- (void)insertText:(NSString *)text {
    [self ensureInputFieldIsVisible:nil];
    if ([text isEqualToString:@"\n"]) {
        HandleKeypress(WKC_RETURN, '\n');
    } else {
        HandleTextInput(text.UTF8String);
    }
}

- (void)deleteBackward {
    [self ensureInputFieldIsVisible:nil];
    HandleKeypress(WKC_BACKSPACE, '\x08');
}

- (void)handleKeypress:(unsigned short)keycode chars:(NSString*)chars {
    [self ensureInputFieldIsVisible:nil];
    
    switch (keycode) {
        case IOS_UP:    HandleKeypress(WKC_UP, 0); break;
        case IOS_DOWN:  HandleKeypress(WKC_DOWN, 0); break;
        case IOS_LEFT:  HandleKeypress(WKC_LEFT, 0); break;
        case IOS_RIGHT: HandleKeypress(WKC_RIGHT, 0); break;
        case IOS_RETURN: HandleKeypress(WKC_RETURN, '\n'); break;
        case IOS_BACKSPACE: HandleKeypress(WKC_BACKSPACE, '\x08'); break;
        default: HandleTextInput(chars.UTF8String); break;
    }
}

- (BOOL)hasText {
    if (_focused_window) {
        return _focused_window->GetFocusedText() != NULL;
    } else {
        return NO;
    }
}

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (keyTimer != nil) [keyTimer invalidate];
    keys = @[].mutableCopy;
    
    [event.allPresses enumerateObjectsUsingBlock:^(UIPress * _Nonnull obj, BOOL * _Nonnull stop) {
        [self keyDown:obj];
    }];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [event.allPresses enumerateObjectsUsingBlock:^(UIPress * _Nonnull obj, BOOL * _Nonnull stop) {
        [self keyUp:obj];
    }];
}

- (void)keyDown:(UIPress *)presse
{
    /* Convert UTF-16 characters to UCS-4 chars. */
    std::vector<WChar> unicode_str = NSStringToUTF32([ presse.key characters ]);
    if (unicode_str.empty()) unicode_str.push_back(0);

    if (EditBoxInGlobalFocus()) {
        if ([ self internalHandleKeycode:presse.key.keyCode unicode:unicode_str[0] pressed:YES modifiers:presse.key.modifierFlags ]) {
            [self handleKeypress:presse.key.keyCode chars:[ presse.key characters ]];
        }
    } else {
        [ self internalHandleKeycode:presse.key.keyCode unicode:unicode_str[0] pressed:YES modifiers:presse.key.modifierFlags ];
        for (size_t i = 1; i < unicode_str.size(); i++) {
            [ self internalHandleKeycode:0 unicode:unicode_str[i] pressed:YES modifiers:presse.key.modifierFlags ];
        }
    }
}

- (void)keyUp:(UIPress *)presse
{
    /* Convert UTF-16 characters to UCS-4 chars. */
    std::vector<WChar> unicode_str = NSStringToUTF32([ presse.key characters ]);
    if (unicode_str.empty()) unicode_str.push_back(0);

    [ self internalHandleKeycode:presse.key.keyCode unicode:unicode_str[0] pressed:NO modifiers:presse.key.modifierFlags ];
}

- (BOOL)internalHandleKeycode:(unsigned short)keycode unicode:(WChar)unicode pressed:(BOOL)down modifiers:(NSUInteger)modifiers
{
    switch (keycode) {
        case IOS_UP:    SB(_dirkeys, 1, 1, down); break;
        case IOS_DOWN:  SB(_dirkeys, 3, 1, down); break;
        case IOS_LEFT:  SB(_dirkeys, 0, 1, down); break;
        case IOS_RIGHT: SB(_dirkeys, 2, 1, down); break;

        case IOS_LCTRL:
        case IOS_RCTRL: _ctrl_pressed = down; break;
            
        case IOS_LSHIFT:
        case IOS_RSHIFT: _shift_pressed = down; break;
            
        case IOS_TAB: _tab_is_down = down; break;

        case IOS_RETURN:
        case IOS_f:
            if (down && (modifiers & OTTD_EventModifierFlagCommand)) {
                VideoDriver::GetInstance()->ToggleFullscreen(!_fullscreen);
            }
            break;

        case IOS_v:
            if (down && EditBoxInGlobalFocus() && (modifiers & (OTTD_EventModifierFlagCommand | OTTD_EventModifierFlagControl))) {
                HandleKeypress(WKC_CTRL | 'V', unicode);
            }
            break;
        case IOS_u:
            if (down && EditBoxInGlobalFocus() && (modifiers & (OTTD_EventModifierFlagCommand | OTTD_EventModifierFlagControl))) {
                HandleKeypress(WKC_CTRL | 'U', unicode);
            }
            break;
    }
    
    BOOL interpret_keys = YES;
    if (down) {
        /* Map keycode to OTTD code. */
        auto vk = std::find_if(std::begin(_vk_mapping), std::end(_vk_mapping), [=](const IOSVkMapping &m) { return m.vk_from == keycode; });
        uint32 pressed_key = vk != std::end(_vk_mapping) ? vk->map_to : 0;

        if (modifiers & OTTD_EventModifierFlagShift)   pressed_key |= WKC_SHIFT;
        if (modifiers & OTTD_EventModifierFlagControl) pressed_key |= (_settings_client.gui.right_mouse_btn_emulation != RMBE_CONTROL ? WKC_CTRL : WKC_META);
        if (modifiers & OTTD_EventModifierFlagOption)  pressed_key |= WKC_ALT;
        if (modifiers & OTTD_EventModifierFlagCommand) pressed_key |= (_settings_client.gui.right_mouse_btn_emulation != RMBE_CONTROL ? WKC_META : WKC_CTRL);

        static bool console = false;

        /* The second backquote may have a character, which we don't want to interpret. */
        if (pressed_key == WKC_BACKQUOTE && (console || unicode == 0)) {
            if (!console) {
                /* Backquote is a dead key, require a double press for hotkey behaviour (i.e. console). */
                console = true;
                return YES;
            } else {
                /* Second backquote, don't interpret as text input. */
                interpret_keys = NO;
            }
        }
        console = false;

        /* Don't handle normal characters if an edit box has the focus. */
        if (!EditBoxInGlobalFocus() || IsInsideMM(pressed_key & ~WKC_SPECIAL_KEYS, WKC_F1, WKC_PAUSE + 1)) {
            HandleKeypress(pressed_key, unicode);
        }
        Debug(driver, 3, "iOS: IOS_KeyEvent: {:x} ({:x}), down, mapping: {:x}", keycode, (int)unicode, pressed_key);
    } else {
        Debug(driver, 3, "iOS: IOS_KeyEvent: {:x} ({:x}), up", keycode, (int)unicode);
    }

    return interpret_keys;
}

static std::vector<WChar> NSStringToUTF32(NSString *s)
{
    std::vector<WChar> unicode_str;

    unichar lead = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [ s characterAtIndex:i ];
        if (Utf16IsLeadSurrogate(c)) {
            lead = c;
            continue;
        } else if (Utf16IsTrailSurrogate(c)) {
            if (lead != 0) unicode_str.push_back(Utf16DecodeSurrogate(lead, c));
        } else {
            unicode_str.push_back(c);
        }
    }

    return unicode_str;
}

@end

