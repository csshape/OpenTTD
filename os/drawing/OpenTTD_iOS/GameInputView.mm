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

extern CALayer *_cocoa_touch_layer;
static GameInputView *_cocoa_input_view;

std::string _keyboard_opt[2];
static WChar _keyboard[2][OSK_KEYBOARD_ENTRIES];

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


@end

