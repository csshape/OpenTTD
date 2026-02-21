/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_glkit_v.mm iOS Metal video driver without SDL2. */

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "../stdafx.h"

#include "../blitter/factory.hpp"
#include "../core/geometry_func.hpp"
#include "../core/math_func.hpp"
#include "../core/utf8.hpp"
#include "../debug.h"
#include "../framerate_type.h"
#include "../gfx_func.h"
#include "../openttd.h"
#include "../settings_type.h"
#include "../viewport_func.h"
#include "../window_func.h"
#include "ios_glkit_v.h"

#include <dispatch/dispatch.h>

static FVideoDriver_iOS_Metal iFVideoDriver_iOS_Metal;
static FVideoDriver_iOS_MetalCompatGLKit iFVideoDriver_iOS_MetalCompatGLKit;
static FVideoDriver_iOS_MetalCompatGLES iFVideoDriver_iOS_MetalCompatGLES;
static FVideoDriver_iOS_MetalCompatSDL iFVideoDriver_iOS_MetalCompatSDL;
static NSString *const kWindowSceneRoleExternalDisplay = @"UIWindowSceneSessionRoleExternalDisplay";

static constexpr uint16_t HID_KEY_A = 0x04;
static constexpr uint16_t HID_KEY_Z = 0x1D;
static constexpr uint16_t HID_KEY_1 = 0x1E;
static constexpr uint16_t HID_KEY_0 = 0x27;
static constexpr uint16_t HID_KEY_RETURN = 0x28;
static constexpr uint16_t HID_KEY_ESCAPE = 0x29;
static constexpr uint16_t HID_KEY_BACKSPACE = 0x2A;
static constexpr uint16_t HID_KEY_TAB = 0x2B;
static constexpr uint16_t HID_KEY_SPACE = 0x2C;
static constexpr uint16_t HID_KEY_MINUS = 0x2D;
static constexpr uint16_t HID_KEY_EQUALS = 0x2E;
static constexpr uint16_t HID_KEY_L_BRACKET = 0x2F;
static constexpr uint16_t HID_KEY_R_BRACKET = 0x30;
static constexpr uint16_t HID_KEY_BACKSLASH = 0x31;
static constexpr uint16_t HID_KEY_SEMICOLON = 0x33;
static constexpr uint16_t HID_KEY_QUOTE = 0x34;
static constexpr uint16_t HID_KEY_BACKQUOTE = 0x35;
static constexpr uint16_t HID_KEY_COMMA = 0x36;
static constexpr uint16_t HID_KEY_PERIOD = 0x37;
static constexpr uint16_t HID_KEY_SLASH = 0x38;
static constexpr uint16_t HID_KEY_F1 = 0x3A;
static constexpr uint16_t HID_KEY_F12 = 0x45;
static constexpr uint16_t HID_KEY_INSERT = 0x49;
static constexpr uint16_t HID_KEY_HOME = 0x4A;
static constexpr uint16_t HID_KEY_PAGEUP = 0x4B;
static constexpr uint16_t HID_KEY_DELETE = 0x4C;
static constexpr uint16_t HID_KEY_END = 0x4D;
static constexpr uint16_t HID_KEY_PAGEDOWN = 0x4E;
static constexpr uint16_t HID_KEY_RIGHT = 0x4F;
static constexpr uint16_t HID_KEY_LEFT = 0x50;
static constexpr uint16_t HID_KEY_DOWN = 0x51;
static constexpr uint16_t HID_KEY_UP = 0x52;
static constexpr uint16_t HID_KEY_KP_DIVIDE = 0x54;
static constexpr uint16_t HID_KEY_KP_MULTIPLY = 0x55;
static constexpr uint16_t HID_KEY_KP_MINUS = 0x56;
static constexpr uint16_t HID_KEY_KP_PLUS = 0x57;
static constexpr uint16_t HID_KEY_KP_ENTER = 0x58;
static constexpr uint16_t HID_KEY_KP_1 = 0x59;
static constexpr uint16_t HID_KEY_KP_9 = 0x61;
static constexpr uint16_t HID_KEY_KP_0 = 0x62;
static constexpr uint16_t HID_KEY_KP_PERIOD = 0x63;
static constexpr NSUInteger IOS_MODIFIER_SHIFT = 1u << 17;
static constexpr NSUInteger IOS_MODIFIER_ALT = 1u << 19;
static constexpr NSUInteger IOS_MODIFIER_COMMAND = 1u << 20;

static NSUInteger GetUIntegerProperty(id object, SEL selector)
{
	if (object == nil || ![object respondsToSelector:selector]) return 0;
	using UIntFn = NSUInteger (*)(id, SEL);
	auto fn = reinterpret_cast<UIntFn>([object methodForSelector:selector]);
	return fn == nullptr ? 0 : fn(object, selector);
}

static NSString *GetNSStringProperty(id object, SEL selector)
{
	if (object == nil || ![object respondsToSelector:selector]) return nil;
	using IdFn = id (*)(id, SEL);
	auto fn = reinterpret_cast<IdFn>([object methodForSelector:selector]);
	if (fn == nullptr) return nil;

	id value = fn(object, selector);
	return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

/** Read the UIKey HID usage code when available (iOS 13.4+). */
static uint16_t GetHIDUsage(id key)
{
	return static_cast<uint16_t>(GetUIntegerProperty(key, @selector(keyCode)));
}

static std::string ToUtf8(NSString *str)
{
	if (str == nil || str.length == 0) return {};
	const char *utf8 = [str UTF8String];
	return utf8 == nullptr ? std::string{} : std::string{utf8};
}

static char32_t FirstUtf8CodePoint(std::string_view text)
{
	auto [len, c] = DecodeUtf8(text);
	return len > 0 ? c : WKC_NONE;
}

static uint MapASCIICharToWKC(char c)
{
	if (c >= 'a' && c <= 'z') return static_cast<uint>(c - ('a' - 'A'));
	if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return static_cast<uint>(c);

	switch (c) {
		case '/': return WKC_SLASH;
		case ';': return WKC_SEMICOLON;
		case '=': return WKC_EQUALS;
		case '[': return WKC_L_BRACKET;
		case '\\': return WKC_BACKSLASH;
		case ']': return WKC_R_BRACKET;
		case '\'': return WKC_SINGLEQUOTE;
		case ',': return WKC_COMMA;
		case '-': return WKC_MINUS;
		case '.': return WKC_PERIOD;
		case '`': return WKC_BACKQUOTE;
		case ' ': return WKC_SPACE;
		default: return 0;
	}
}

static uint MapHIDUsageToWKC(uint16_t usage, bool &unprintable)
{
	unprintable = false;

	if (usage >= HID_KEY_A && usage <= HID_KEY_Z) return static_cast<uint>('A' + (usage - HID_KEY_A));
	if (usage >= HID_KEY_F1 && usage <= HID_KEY_F12) {
		unprintable = true;
		return static_cast<uint>(WKC_F1 + (usage - HID_KEY_F1));
	}
	if (usage >= HID_KEY_1 && usage < HID_KEY_0) return static_cast<uint>('1' + (usage - HID_KEY_1));
	if (usage >= HID_KEY_KP_1 && usage <= HID_KEY_KP_9) return static_cast<uint>('1' + (usage - HID_KEY_KP_1));

	switch (usage) {
		case HID_KEY_1: return '1';
		case HID_KEY_0: return '0';
		case HID_KEY_RETURN: unprintable = true; return WKC_RETURN;
		case HID_KEY_ESCAPE: unprintable = true; return WKC_ESC;
		case HID_KEY_BACKSPACE: unprintable = true; return WKC_BACKSPACE;
		case HID_KEY_TAB: unprintable = true; return WKC_TAB;
		case HID_KEY_SPACE: return WKC_SPACE;
		case HID_KEY_MINUS: return WKC_MINUS;
		case HID_KEY_EQUALS: return WKC_EQUALS;
		case HID_KEY_L_BRACKET: return WKC_L_BRACKET;
		case HID_KEY_R_BRACKET: return WKC_R_BRACKET;
		case HID_KEY_BACKSLASH: return WKC_BACKSLASH;
		case HID_KEY_SEMICOLON: return WKC_SEMICOLON;
		case HID_KEY_QUOTE: return WKC_SINGLEQUOTE;
		case HID_KEY_BACKQUOTE: return WKC_BACKQUOTE;
		case HID_KEY_COMMA: return WKC_COMMA;
		case HID_KEY_PERIOD: return WKC_PERIOD;
		case HID_KEY_SLASH: return WKC_SLASH;
		case HID_KEY_INSERT: unprintable = true; return WKC_INSERT;
		case HID_KEY_HOME: unprintable = true; return WKC_HOME;
		case HID_KEY_PAGEUP: unprintable = true; return WKC_PAGEUP;
		case HID_KEY_DELETE: unprintable = true; return WKC_DELETE;
		case HID_KEY_END: unprintable = true; return WKC_END;
		case HID_KEY_PAGEDOWN: unprintable = true; return WKC_PAGEDOWN;
		case HID_KEY_LEFT: unprintable = true; return WKC_LEFT;
		case HID_KEY_RIGHT: unprintable = true; return WKC_RIGHT;
		case HID_KEY_UP: unprintable = true; return WKC_UP;
		case HID_KEY_DOWN: unprintable = true; return WKC_DOWN;
		case HID_KEY_KP_0: return '0';
		case HID_KEY_KP_DIVIDE: return WKC_NUM_DIV;
		case HID_KEY_KP_MULTIPLY: return WKC_NUM_MUL;
		case HID_KEY_KP_MINUS: return WKC_NUM_MINUS;
		case HID_KEY_KP_PLUS: return WKC_NUM_PLUS;
		case HID_KEY_KP_ENTER: unprintable = true; return WKC_NUM_ENTER;
		case HID_KEY_KP_PERIOD: return WKC_NUM_DECIMAL;
		default: return 0;
	}
}

static uint ConvertIOSKeyIntoMy(id key, char32_t &character, std::string &text)
{
	character = WKC_NONE;
	text = ToUtf8(GetNSStringProperty(key, @selector(characters)));

	bool unprintable = false;
	uint base = MapHIDUsageToWKC(GetHIDUsage(key), unprintable);

	/* Older iOS versions do not expose keyCode; recover what we can from text. */
	if (base == 0) {
		NSString *ignoring = GetNSStringProperty(key, @selector(charactersIgnoringModifiers));
		if (ignoring != nil && ignoring.length == 1) {
			std::string fallback = ToUtf8(ignoring);
			if (!fallback.empty()) base = MapASCIICharToWKC(fallback[0]);
		} else if ([ignoring isEqualToString:UIKeyInputUpArrow]) {
			unprintable = true;
			base = WKC_UP;
		} else if ([ignoring isEqualToString:UIKeyInputDownArrow]) {
			unprintable = true;
			base = WKC_DOWN;
		} else if ([ignoring isEqualToString:UIKeyInputLeftArrow]) {
			unprintable = true;
			base = WKC_LEFT;
		} else if ([ignoring isEqualToString:UIKeyInputRightArrow]) {
			unprintable = true;
			base = WKC_RIGHT;
		}
	}

	uint keycode = base;
	NSUInteger mods = GetUIntegerProperty(key, @selector(modifierFlags));
	if ((mods & IOS_MODIFIER_SHIFT) != 0) keycode |= WKC_SHIFT;
	if ((mods & IOS_MODIFIER_ALT) != 0) keycode |= WKC_ALT;
	if ((mods & IOS_MODIFIER_COMMAND) != 0) keycode |= WKC_CTRL; // Cmd acts as PC Ctrl on iPad.

	bool suppress_character = unprintable || (keycode & (WKC_CTRL | WKC_ALT | WKC_META)) != 0;
	if (!suppress_character && !text.empty()) {
		character = FirstUtf8CodePoint(text);
	}

	return keycode;
}

/** Minimal UIView subclass with CAMetalLayer backing and touch input. */
@interface OTTDMetalView : UIView {
@private
	VideoDriver_iOS_Metal *_driver; ///< Bridge to the C++ input pipeline.
	CGPoint _single_touch_prev;   ///< Previous single-touch location in view points.
	CGPoint _pan_prev_centroid;   ///< Previous two-finger centroid in view points.
	CGPoint _hover_prev;          ///< Previous hover location for indirect pointer relative movement.
	bool    _hover_has_prev;      ///< True once we have a previous hover sample.
	bool    _in_two_finger_pan;   ///< Whether we are currently in two-finger pan mode.
	CGFloat _pinch_prev_dist;     ///< Spread (distance) between two active fingers, in view points.
	float   _pinch_accum;         ///< Accumulated pinch-magnitude (fraction of a zoom step).
}
- (void)setDriver:(VideoDriver_iOS_Metal *)driver;
@end

/** Return the spread (distance) between the first two active touches in view coordinates. */
static CGFloat SpreadOfActiveTouches(NSSet<UITouch *> *all, UIView *v)
{
	CGPoint pts[2];
	NSUInteger n = 0;
	for (UITouch *t in all) {
		if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
		pts[n++] = [t locationInView:v];
		if (n == 2) break;
	}
	if (n < 2) return 0.0;
	CGFloat dx = pts[0].x - pts[1].x, dy = pts[0].y - pts[1].y;
	return sqrt(dx * dx + dy * dy);
}

/** Return the centroid of all non-ended touches in view coordinates. */
static CGPoint CentroidOfActiveTouches(NSSet<UITouch *> *all, UIView *v)
{
	CGFloat x = 0.0, y = 0.0;
	NSUInteger n = 0;
	for (UITouch *t in all) {
		if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
		CGPoint p = [t locationInView:v];
		x += p.x; y += p.y; n++;
	}
	if (n == 0) return CGPointZero;
	return CGPointMake(x / n, y / n);
}

/** Count the number of touches that are still active (not ended/cancelled). */
static NSUInteger CountActiveTouches(NSSet<UITouch *> *all)
{
	NSUInteger n = 0;
	for (UITouch *t in all) {
		if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) n++;
	}
	return n;
}

static bool IsSecondaryMouseButtonPressed(UIEvent *event)
{
	if (event == nil) return false;
	if (@available(iOS 13.4, *)) {
		return (event.buttonMask & 2u) != 0; // UIEventButtonMaskSecondary
	}
	return false;
}

@implementation OTTDMetalView

+ (Class)layerClass
{
	return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		_driver = nullptr;
		self.multipleTouchEnabled = YES;
		_in_two_finger_pan = false;
		_single_touch_prev = CGPointZero;
		_pan_prev_centroid = CGPointZero;
		_hover_prev = CGPointZero;
		_hover_has_prev = false;
		_pinch_prev_dist = 0.0;
		_pinch_accum = 0.0f;

		/* Long press (0.5 s) acts as a right-click to open context menus. */
		UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
			initWithTarget:self action:@selector(_ottd_longPress:)];
		lp.minimumPressDuration = 0.5;
		[self addGestureRecognizer:lp];
		[lp release];

		/* Hover/mouse pointer movement updates cursor without requiring touch-down. */
		UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc]
			initWithTarget:self action:@selector(_ottd_hover:)];
		[self addGestureRecognizer:hover];
		[hover release];
	}
	return self;
}

- (void)setDriver:(VideoDriver_iOS_Metal *)driver
{
	_driver = driver;
}

- (BOOL)canBecomeFirstResponder
{
	return YES;
}

- (void)didMoveToWindow
{
	[super didMoveToWindow];
	if (self.window != nil) [self becomeFirstResponder];
}

/** Convert a view-space point to game pixel coordinates. */
- (CGPoint)_pixelPoint:(CGPoint)pt
{
	CGSize bounds = self.bounds.size;
	if (bounds.width > 0.0 && bounds.height > 0.0 && _screen.width > 0 && _screen.height > 0) {
		CGFloat sx = (CGFloat)_screen.width / bounds.width;
		CGFloat sy = (CGFloat)_screen.height / bounds.height;
		return CGPointMake(pt.x * sx, pt.y * sy);
	}

	CGFloat sx = self.contentScaleFactor > 0.0 ? self.contentScaleFactor : 1.0;
	CGFloat sy = sx;
	if (bounds.width > 0.0 && bounds.height > 0.0) {
		if ([self.layer isKindOfClass:[CAMetalLayer class]]) {
			CAMetalLayer *layer = (CAMetalLayer *)self.layer;
			CGSize drawable = layer.drawableSize;
			if (drawable.width > 0.0 && drawable.height > 0.0) {
				sx = drawable.width / bounds.width;
				sy = drawable.height / bounds.height;
			}
		}
	}
	return CGPointMake(pt.x * sx, pt.y * sy);
}

/** Convert delta in view points to game pixels, using current drawable-to-view ratio. */
- (CGPoint)_pixelDelta:(CGPoint)delta
{
	CGPoint p0 = [self _pixelPoint:CGPointZero];
	CGPoint p1 = [self _pixelPoint:CGPointMake(delta.x, delta.y)];
	return CGPointMake(p1.x - p0.x, p1.y - p0.y);
}

- (void)_ottd_hover:(UIHoverGestureRecognizer *)rec
{
	if (_driver == nullptr) return;

	CGPoint pt = [rec locationInView:self];
	if (rec.state == UIGestureRecognizerStateBegan) {
		_hover_prev = pt;
		_hover_has_prev = true;
	}

	if (_cursor.fix_at && _hover_has_prev) {
		CGPoint d = [self _pixelDelta:CGPointMake(pt.x - _hover_prev.x, pt.y - _hover_prev.y)];
		_cursor.UpdateCursorPositionRelative((int)d.x, (int)d.y);
	} else {
		CGPoint px = [self _pixelPoint:pt];
		_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		_cursor.in_window = true;
	}
	_hover_prev = pt;
	_hover_has_prev = true;
	HandleMouseEvents();

	if (rec.state == UIGestureRecognizerStateEnded || rec.state == UIGestureRecognizerStateCancelled || rec.state == UIGestureRecognizerStateFailed) {
		_hover_has_prev = false;
	}
}

- (void)_ottdHandleKeyPresses:(NSSet<UIPress *> *)presses down:(BOOL)down
{
	for (UIPress *press in presses) {
		id key = nil;
		SEL key_selector = @selector(key);
		if ([press respondsToSelector:key_selector]) {
			using KeyFn = id (*)(id, SEL);
			auto key_fn = reinterpret_cast<KeyFn>([press methodForSelector:key_selector]);
			if (key_fn != nullptr) key = key_fn(press, key_selector);
		}
		if (key == nil) continue;

		NSUInteger mods = GetUIntegerProperty(key, @selector(modifierFlags));
		bool command = (mods & IOS_MODIFIER_COMMAND) != 0;
		bool shift = (mods & IOS_MODIFIER_SHIFT) != 0;
		bool alt = (mods & IOS_MODIFIER_ALT) != 0;

		if (_driver == nullptr) continue;
		_driver->OnHardwareModifierState(command, shift, alt);

		char32_t character = WKC_NONE;
		std::string text{};
		uint keycode = ConvertIOSKeyIntoMy(key, character, text);

		if (down) {
			_driver->OnHardwareKeyDown(keycode, character, text);
		} else {
			_driver->OnHardwareKeyUp(keycode);
		}
	}
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	[self _ottdHandleKeyPresses:presses down:YES];
	[super pressesBegan:presses withEvent:event];
}

- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	[self _ottdHandleKeyPresses:presses down:YES];
	[super pressesChanged:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	[self _ottdHandleKeyPresses:presses down:NO];
	[super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event
{
	[self _ottdHandleKeyPresses:presses down:NO];
	[super pressesCancelled:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	NSSet<UITouch *> *all = event.allTouches;
	NSUInteger active = CountActiveTouches(all);

	if (active >= 2 && !_in_two_finger_pan) {
		/* Switch to two-finger pan (map scroll) mode. */
		_in_two_finger_pan = true;

		/* Release the left button in case it was pressed by a prior single touch. */
		_left_button_down = false;
		_left_button_clicked = false;

		CGPoint cen = CentroidOfActiveTouches(all, self);
		_pan_prev_centroid = cen;
		CGPoint px = [self _pixelPoint:cen];
		_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		_cursor.in_window = true;

		_pinch_prev_dist = SpreadOfActiveTouches(all, self);
		_pinch_accum = 0.0f;

		/* Simulate a right-button press so the viewport scrolls. */
		_right_button_down = true;
		_right_button_clicked = true;
	} else if (active == 1 && !_in_two_finger_pan) {
		UITouch *t = touches.anyObject;
		CGPoint pt = [t locationInView:self];
		_single_touch_prev = pt;
		CGPoint px = [self _pixelPoint:pt];
		_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		_cursor.in_window = true;

		if (IsSecondaryMouseButtonPressed(event)) {
			_left_button_down = false;
			_left_button_clicked = false;
			_right_button_down = true;
			_right_button_clicked = true;
		} else {
			_right_button_down = false;
			_right_button_clicked = false;
			_left_button_down = true;
		}
		HandleMouseEvents();
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	NSSet<UITouch *> *all = event.allTouches;

	if (_in_two_finger_pan) {
		CGPoint cen = CentroidOfActiveTouches(all, self);
		if (_cursor.fix_at) {
			/* Cursor is locked (e.g. during map drag); supply relative delta. */
			CGPoint d = [self _pixelDelta:CGPointMake(cen.x - _pan_prev_centroid.x, cen.y - _pan_prev_centroid.y)];
			int dx = (int)d.x;
			int dy = (int)d.y;
			_cursor.UpdateCursorPositionRelative(dx, dy);
		} else {
			CGPoint px = [self _pixelPoint:cen];
			_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		}
		_pan_prev_centroid = cen;

		/* Pinch-zoom: accumulate spread change and emit discrete zoom steps.
		 * We call ZoomInOrOutToCursorWindow() directly instead of routing
		 * through HandleMouseEvents(), because HandleViewportScroll() returns
		 * ES_HANDLED while the right-button pan is active, which would block
		 * the mousewheel path in MouseLoop entirely. */
		CGFloat new_dist = SpreadOfActiveTouches(all, self);
		if (_pinch_prev_dist > 0.0 && new_dist > 0.0) {
			_pinch_accum += log2f((float)(new_dist / _pinch_prev_dist)) * 3.0f;
			Window *main_w = GetMainWindow();
			if (main_w != nullptr) {
				while (_pinch_accum >= 1.0f) {
					_pinch_accum -= 1.0f;
					ZoomInOrOutToCursorWindow(true, main_w);   /* zoom in */
				}
				while (_pinch_accum <= -1.0f) {
					_pinch_accum += 1.0f;
					ZoomInOrOutToCursorWindow(false, main_w);  /* zoom out */
				}
			}
		}
		_pinch_prev_dist = new_dist;
	} else {
		/* Find the moved/stationary touch. */
		UITouch *t = nil;
		for (UITouch *touch in all) {
			if (touch.phase == UITouchPhaseMoved || touch.phase == UITouchPhaseStationary) {
				t = touch;
				break;
			}
		}
		if (t == nil) t = all.anyObject;

		CGPoint pt = [t locationInView:self];
		if (_cursor.fix_at) {
			CGPoint d = [self _pixelDelta:CGPointMake(pt.x - _single_touch_prev.x, pt.y - _single_touch_prev.y)];
			int dx = (int)d.x;
			int dy = (int)d.y;
			_cursor.UpdateCursorPositionRelative(dx, dy);
		} else {
			CGPoint px = [self _pixelPoint:pt];
			_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		}
		_single_touch_prev = pt;

		if (IsSecondaryMouseButtonPressed(event)) {
			_left_button_down = false;
			_left_button_clicked = false;
			_right_button_down = true;
		} else {
			_right_button_down = false;
			_right_button_clicked = false;
			_left_button_down = true;
		}
		HandleMouseEvents();
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	NSSet<UITouch *> *all = event.allTouches;
	NSUInteger remaining = CountActiveTouches(all);

	if (_in_two_finger_pan) {
		if (remaining < 2) {
			_right_button_down = false;
			_right_button_clicked = false;
			_in_two_finger_pan = false;
			_pinch_prev_dist = 0.0;
			_pinch_accum = 0.0f;

			if (remaining == 1) {
				/* Resume single-touch tracking for the remaining finger. */
				for (UITouch *t in all) {
					if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) {
						CGPoint pt = [t locationInView:self];
						_single_touch_prev = pt;
						CGPoint px = [self _pixelPoint:pt];
						_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
						break;
					}
				}
			}
		}
	} else {
		if (remaining == 0) {
			_right_button_down = false;
			_right_button_clicked = false;
			_left_button_down = false;
			_left_button_clicked = false;
			HandleMouseEvents();
		}
	}
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self touchesEnded:touches withEvent:event];
}

- (void)_ottd_longPress:(UILongPressGestureRecognizer *)rec
{
	if (rec.state == UIGestureRecognizerStateBegan) {
		/* Cancel any in-progress left click and trigger a right-click instead. */
		_left_button_down = false;
		_left_button_clicked = false;
		CGPoint pt = [rec locationInView:self];
		CGPoint px = [self _pixelPoint:pt];
		_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		_right_button_down = true;
		_right_button_clicked = true;
	} else if (rec.state == UIGestureRecognizerStateEnded ||
	           rec.state == UIGestureRecognizerStateCancelled ||
	           rec.state == UIGestureRecognizerStateFailed) {
		_right_button_down = false;
		_right_button_clicked = false;
	}
}

@end

/** Input-only view used on the iPad screen while rendering on an external display. */
@interface OTTDInputProxyView : OTTDMetalView
@end

@implementation OTTDInputProxyView

+ (Class)layerClass
{
	return [CALayer class];
}

@end

/** Objective-C bridge object for CADisplayLink callback. */
@interface OTTD_iOSDisplayLinkTarget : NSObject {
@public
	VideoDriver_iOS_Metal *driver;
}
- (void)onDisplayLink:(CADisplayLink *)displayLink;
@end

@implementation OTTD_iOSDisplayLinkTarget
- (void)onDisplayLink:(__unused CADisplayLink *)displayLink
{
	if (driver != nullptr) driver->OnDisplayFrame();
}
@end

@interface OTTD_iOSScreenObserver : NSObject {
@public
	VideoDriver_iOS_Metal *driver;
}
- (void)onScreenChanged:(NSNotification *)notification;
@end

@implementation OTTD_iOSScreenObserver
- (void)onScreenChanged:(__unused NSNotification *)notification
{
	if (driver != nullptr) driver->HandleScreenTopologyChanged();
}
@end

@interface OTTDViewController : UIViewController {
@public
	VideoDriver_iOS_Metal *driver;
}
@end

@implementation OTTDViewController

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	if (self->driver == nullptr) return;
	[coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
		if (self->driver != nullptr) self->driver->NotifySizeChanged();
	}];
}

- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	if (self->driver != nullptr) self->driver->NotifySizeChanged();
}

@end

static void RunOnMainThreadSync(dispatch_block_t block)
{
	if ([NSThread isMainThread]) {
		block();
		return;
	}
	dispatch_sync(dispatch_get_main_queue(), block);
}

static CGSize GetPixelSizeForScreen(UIScreen *screen)
{
	if (screen == nil) return CGSizeMake(0.0, 0.0);

	UIScreenMode *mode = screen.currentMode;
	if (mode != nil && mode.size.width > 0.0 && mode.size.height > 0.0) {
		return mode.size;
	}

	CGRect native = screen.nativeBounds;
	if (native.size.width > 0.0 && native.size.height > 0.0) {
		return native.size;
	}

	CGRect bounds = screen.bounds;
	CGFloat scale = screen.scale > 0.0 ? screen.scale : 1.0;
	return CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
}

static uint64_t GetScreenPixelArea(UIScreen *screen)
{
	CGSize size = GetPixelSizeForScreen(screen);
	if (size.width <= 0.0 || size.height <= 0.0) return 0;
	return static_cast<uint64_t>(size.width) * static_cast<uint64_t>(size.height);
}

static UIScreen *PickPreferredScreen()
{
	UIScreen *main = [UIScreen mainScreen];
	UIScreen *preferred = main;
	uint64_t preferred_pixels = 0;

	NSArray<UIScreen *> *screens = [UIScreen screens];
	for (UIScreen *screen in screens) {
		if (screen == main) continue;

		uint64_t pixels = GetScreenPixelArea(screen);
		if (preferred == main || pixels > preferred_pixels) {
			preferred = screen;
			preferred_pixels = pixels;
		}
	}

	return preferred;
}

static UIWindowScene *FindWindowSceneForScreen(UIScreen *screen)
{
	UIApplication *app = [UIApplication sharedApplication];
	for (UIScene *scene in app.connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		UIWindowScene *window_scene = (UIWindowScene *)scene;
		if (screen == nil || window_scene.screen == screen) return window_scene;
	}
	return nil;
}

static UIWindow *FindWindowForScreen(UIScreen *screen)
{
	UIWindowScene *window_scene = FindWindowSceneForScreen(screen);
	if (window_scene != nil) {
		for (UIWindow *window in window_scene.windows) {
			if (window != nil) return window;
		}
	}

	UIApplication *app = [UIApplication sharedApplication];
	for (UIWindow *window in app.windows) {
		if (window == nil) continue;
		if (window.windowScene != nil && screen != nil && window.windowScene.screen != screen) continue;
		return window;
	}
	return nil;
}

static CGFloat GetViewScaleForScreen(UIScreen *screen)
{
	if (screen == nil) return 1.0;
	if (screen.nativeScale > 0.0) return screen.nativeScale;
	if (screen.scale > 0.0) return screen.scale;
	return 1.0;
}

static uint64_t GetModePixelArea(UIScreenMode *mode)
{
	if (mode == nil) return 0;
	CGSize size = mode.size;
	if (size.width <= 0.0 || size.height <= 0.0) return 0;
	return static_cast<uint64_t>(size.width) * static_cast<uint64_t>(size.height);
}

static bool IsUHD4KMode(UIScreenMode *mode)
{
	if (mode == nil) return false;
	CGSize size = mode.size;
	int w = static_cast<int>(size.width);
	int h = static_cast<int>(size.height);
	return (w == 3840 && h == 2160) || (w == 2160 && h == 3840);
}

static void ConfigureScreenForMaximumResolution(UIScreen *screen)
{
	if (screen == nil || screen == [UIScreen mainScreen]) return;

	NSArray<UIScreenMode *> *modes = screen.availableModes;
	if (modes.count == 0) return;

	UIScreenMode *fourk_mode = nil;
	UIScreenMode *best_mode = screen.currentMode;
	uint64_t best_pixels = GetModePixelArea(best_mode);

	for (UIScreenMode *mode in modes) {
		if (fourk_mode == nil && IsUHD4KMode(mode)) fourk_mode = mode;

		uint64_t pixels = GetModePixelArea(mode);
		if (pixels > best_pixels) {
			best_mode = mode;
			best_pixels = pixels;
		}
	}

	UIScreenMode *target_mode = fourk_mode != nil ? fourk_mode : best_mode;
	if (target_mode != nil && target_mode != screen.currentMode) {
		screen.currentMode = target_mode;
		if (fourk_mode != nil) {
			Debug(driver, 1, "iOS Metal: selected external 4K mode 3840x2160");
		} else {
			CGSize size = target_mode.size;
			Debug(driver, 1, "iOS Metal: 4K mode unavailable, selected highest mode {}x{}", static_cast<int>(size.width), static_cast<int>(size.height));
		}
	}

	UIScreenMode *active_mode = screen.currentMode;
	if (active_mode != nil) {
		CGSize size = active_mode.size;
		Debug(driver, 1, "iOS Metal: active screen mode {}x{}", static_cast<int>(size.width), static_cast<int>(size.height));
	}
}

/* Fullscreen textured quad shaders. */
static const char *metal_shader_src = R"(
	#include <metal_stdlib>
	using namespace metal;

	struct VSOut {
		float4 position [[position]];
		float2 uv;
	};

	vertex VSOut vs_main(uint vid [[vertex_id]]) {
		constexpr float2 positions[4] = {
			float2(-1.0, -1.0),
			float2( 1.0, -1.0),
			float2(-1.0,  1.0),
			float2( 1.0,  1.0)
		};
		constexpr float2 uvs[4] = {
			float2(0.0, 1.0),
			float2(1.0, 1.0),
			float2(0.0, 0.0),
			float2(1.0, 0.0)
		};

		VSOut out;
		out.position = float4(positions[vid], 0.0, 1.0);
		out.uv = uvs[vid];
		return out;
	}

	/* 32bpp direct BGRA path. */
	fragment half4 fs_main(VSOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
		constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
		return tex.sample(s, in.uv);
	}

	/* 8bpp indexed colour path: sample palette index then look up colour on GPU. */
	fragment half4 fs_main_indexed(VSOut in [[stage_in]],
	                               texture2d<uint> idx_tex [[texture(0)]],
	                               texture1d<half> palette  [[texture(1)]]) {
		constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
		uint idx = idx_tex.sample(s, in.uv).r;
		return palette.read(idx);
	}
)";

Dimension VideoDriver_iOS_Metal::GetScreenSize() const
{
	__block Dimension result = VideoDriver::GetScreenSize();

	RunOnMainThreadSync(^{
		UIScreen *screen = (UIScreen *)this->active_screen;
		if (screen == nil) screen = PickPreferredScreen();
		ConfigureScreenForMaximumResolution(screen);

		CGSize size = GetPixelSizeForScreen(screen);
		if (size.width > 0.0 && size.height > 0.0) {
			result = { static_cast<uint>(size.width), static_cast<uint>(size.height) };
		}
	});

	return result;
}

bool VideoDriver_iOS_Metal::SetupContextAndView()
{
	__block bool ok = true;

	RunOnMainThreadSync(^{
		UIScreen *screen = PickPreferredScreen();
		if (screen == nil) {
			ok = false;
			return;
		}
		ConfigureScreenForMaximumResolution(screen);

		UIWindow *window = FindWindowForScreen(screen);

		if (window == nil) {
			UIWindowScene *window_scene = FindWindowSceneForScreen(screen);
			if (window_scene != nil) {
				window = [[[UIWindow alloc] initWithWindowScene:window_scene] autorelease];
			}
		}

		if (window == nil) {
			window = [[[UIWindow alloc] initWithFrame:screen.bounds] autorelease];
		}
		if (window == nil) {
			ok = false;
			return;
		}
		if (window.windowScene == nil) {
			window.screen = screen;
			window.frame = screen.bounds;
		} else {
			window.frame = window.windowScene.screen.bounds;
		}
		window.backgroundColor = [UIColor blackColor];

		OTTDViewController *ottd_root = [[[OTTDViewController alloc] init] autorelease];
		ottd_root->driver = this;
		window.rootViewController = ottd_root;
		UIViewController *root = ottd_root;
		root.view.backgroundColor = [UIColor blackColor];
		root.view.frame = window.bounds;

		(void)root.view;

		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			ok = false;
			return;
		}

		OTTDMetalView *view = [[[OTTDMetalView alloc] initWithFrame:root.view.bounds] autorelease];
		if (view == nil) {
			ok = false;
			return;
		}
		[view setDriver:this];

		view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		view.frame = root.view.bounds;

		CGFloat scale = GetViewScaleForScreen(screen);
		view.contentScaleFactor = scale;

		CAMetalLayer *layer = (CAMetalLayer *)view.layer;
		layer.device = device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.framebufferOnly = YES;
		layer.contentsScale = scale;
		CGSize pixel_size = GetPixelSizeForScreen(screen);
		if (pixel_size.width < 1.0 || pixel_size.height < 1.0) {
			pixel_size = CGSizeMake(view.bounds.size.width * scale, view.bounds.size.height * scale);
		}
		layer.drawableSize = CGSizeMake(std::max(1.0, pixel_size.width), std::max(1.0, pixel_size.height));

		[root.view addSubview:view];
		[window makeKeyAndVisible];
		[view becomeFirstResponder];

		UIScreen *old_screen = (UIScreen *)this->active_screen;
		if (old_screen != screen) {
			if (old_screen != nil) [old_screen release];
			this->active_screen = [screen retain];
		}
		this->using_external_screen = (screen != [UIScreen mainScreen]);

		this->ui_window = [window retain];
		this->root_controller = [root retain];
		this->metal_view = [view retain];
		this->metal_layer = [layer retain];
		this->metal_device = [device retain];
	});

	if (ok) this->UpdateInputProxyView();

	return ok;
}

void VideoDriver_iOS_Metal::UpdateInputProxyView()
{
	RunOnMainThreadSync(^{
		OTTDMetalView *proxy = (OTTDMetalView *)this->input_proxy_view;

		if (!this->using_external_screen) {
			if (proxy != nil) {
				[proxy setDriver:nullptr];
				[proxy removeFromSuperview];
				[proxy release];
			}
			this->input_proxy_view = nullptr;
			return;
		}

		UIWindow *main_window = FindWindowForScreen([UIScreen mainScreen]);
		if (main_window == nil) return;

		UIViewController *root = main_window.rootViewController;
		if (root == nil) {
			root = [[[UIViewController alloc] init] autorelease];
			root.view.backgroundColor = [UIColor blackColor];
			main_window.rootViewController = root;
		}

		UIView *container = root.view;
		if (container == nil) return;

		if (proxy == nil) {
			proxy = [[OTTDInputProxyView alloc] initWithFrame:container.bounds];
			proxy.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
			proxy.backgroundColor = [UIColor clearColor];
			proxy.opaque = NO;
			[container addSubview:proxy];
			this->input_proxy_view = proxy;
		} else if (proxy.superview != container) {
			[proxy removeFromSuperview];
			proxy.frame = container.bounds;
			[container addSubview:proxy];
		} else {
			proxy.frame = container.bounds;
		}

		bool allow_proxy_input = true;
		UIWindow *active_window = FindWindowForScreen((UIScreen *)this->active_screen);
		if (active_window != nil && active_window.windowScene != nil) {
			NSString *role = active_window.windowScene.session.role;
			if ([role isEqualToString:kWindowSceneRoleExternalDisplay]) {
				/* External display scene is interactive; prefer pointer/keyboard focus there. */
				allow_proxy_input = false;
			}
		}

		proxy.userInteractionEnabled = allow_proxy_input;
		proxy.hidden = !allow_proxy_input;
		[proxy setDriver:this];
		if (allow_proxy_input) {
			[container bringSubviewToFront:proxy];
			[proxy becomeFirstResponder];
		} else {
			UIView *active_view = (UIView *)this->metal_view;
			if (active_view != nil) [active_view becomeFirstResponder];
		}
	});
}

void VideoDriver_iOS_Metal::RegisterScreenNotifications()
{
	RunOnMainThreadSync(^{
		if (this->screen_observer != nullptr) return;

		OTTD_iOSScreenObserver *observer = [[OTTD_iOSScreenObserver alloc] init];
		observer->driver = this;

		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver:observer selector:@selector(onScreenChanged:) name:UIScreenDidConnectNotification object:nil];
		[center addObserver:observer selector:@selector(onScreenChanged:) name:UIScreenDidDisconnectNotification object:nil];
		[center addObserver:observer selector:@selector(onScreenChanged:) name:UIScreenModeDidChangeNotification object:nil];

		this->screen_observer = observer;
	});
}

void VideoDriver_iOS_Metal::UnregisterScreenNotifications()
{
	RunOnMainThreadSync(^{
		OTTD_iOSScreenObserver *observer = (OTTD_iOSScreenObserver *)this->screen_observer;
		if (observer == nil) return;

		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center removeObserver:observer];
		observer->driver = nullptr;
		[observer release];
		this->screen_observer = nullptr;
	});
}

void VideoDriver_iOS_Metal::HandleScreenTopologyChanged()
{
	__block bool should_rebuild = false;
	__block bool had_display_link = false;

	RunOnMainThreadSync(^{
		UIScreen *preferred = PickPreferredScreen();
		ConfigureScreenForMaximumResolution(preferred);

		UIScreen *current = (UIScreen *)this->active_screen;
		should_rebuild = (current == nil || preferred == nil || current != preferred);
		this->using_external_screen = (preferred != nil && preferred != [UIScreen mainScreen]);
		if (!should_rebuild) {
			this->driver_info = this->using_external_screen ? "ios-metal (Metal, external display)" : "ios-metal (Metal)";

			UIWindow *window = (UIWindow *)this->ui_window;
			UIView *view = (UIView *)this->metal_view;
			CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
			CGRect target_bounds = preferred.bounds;
			if (window != nil) {
				if (window.windowScene == nil) {
					window.frame = preferred.bounds;
				} else {
					window.frame = window.windowScene.screen.bounds;
				}
				target_bounds = window.bounds;
			}
			CGFloat scale = GetViewScaleForScreen(preferred);
			if (view != nil) {
				view.frame = target_bounds;
				view.contentScaleFactor = scale;
			}
			if (layer != nil) {
				layer.contentsScale = scale;
				CGSize pixel_size = GetPixelSizeForScreen(preferred);
				if (pixel_size.width < 1.0 || pixel_size.height < 1.0) {
					pixel_size = CGSizeMake(target_bounds.size.width * scale, target_bounds.size.height * scale);
				}
				layer.drawableSize = CGSizeMake(std::max(1.0, pixel_size.width), std::max(1.0, pixel_size.height));
			}

			CGSize current_size = GetPixelSizeForScreen(preferred);
			if (current_size.width > 0.0 && current_size.height > 0.0) {
				_cur_resolution.width = static_cast<uint>(current_size.width);
				_cur_resolution.height = static_cast<uint>(current_size.height);
			}
		}

		had_display_link = (this->display_link != nullptr);
	});

	this->UpdateInputProxyView();

	if (should_rebuild) {
		this->StopDisplayLink();
		this->TeardownContextAndView();

		if (!this->SetupContextAndView()) {
			Debug(driver, 0, "iOS Metal: Failed to rebuild context after screen topology change");
			return;
		}
		if (!this->InitMetalPipeline()) {
			Debug(driver, 0, "iOS Metal: Failed to rebuild Metal pipeline after screen topology change");
			return;
		}
		if (!this->AllocateBackingStore(_cur_resolution.width, _cur_resolution.height, true)) {
			Debug(driver, 0, "iOS Metal: Failed to rebuild backing store after screen topology change");
			return;
		}

		Dimension screen_size = this->GetScreenSize();
		_resolutions.clear();
		_resolutions.push_back(screen_size);
		_cur_resolution = screen_size;
		this->driver_info = this->using_external_screen ? "ios-metal (Metal, external display)" : "ios-metal (Metal)";

		if (had_display_link && !this->StartDisplayLink()) {
			Debug(driver, 0, "iOS Metal: Failed to restart display link after screen topology change");
		}
		return;
	}

	this->NotifySizeChanged();
}

bool VideoDriver_iOS_Metal::InitMetalPipeline()
{
	__block bool ok = true;

	RunOnMainThreadSync(^{
		id<MTLDevice> device = (id<MTLDevice>)this->metal_device;
		if (device == nil) {
			ok = false;
			return;
		}

		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			ok = false;
			return;
		}

		NSError *error = nil;
		NSString *shader_source = [NSString stringWithUTF8String:metal_shader_src];
		id<MTLLibrary> library = [device newLibraryWithSource:shader_source options:nil error:&error];
		if (library == nil) {
			if (error != nil) Debug(driver, 0, "iOS Metal: shader compile failed: {}", [[error localizedDescription] UTF8String]);
			[queue release];
			ok = false;
			return;
		}

		id<MTLFunction> vertex_function = [library newFunctionWithName:@"vs_main"];
		id<MTLFunction> fragment_function = [library newFunctionWithName:@"fs_main"];
		id<MTLFunction> fragment_function_indexed = [library newFunctionWithName:@"fs_main_indexed"];
		if (vertex_function == nil || fragment_function == nil || fragment_function_indexed == nil) {
			if (vertex_function != nil) [vertex_function release];
			if (fragment_function != nil) [fragment_function release];
			if (fragment_function_indexed != nil) [fragment_function_indexed release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		/* 32bpp direct BGRA pipeline. */
		MTLRenderPipelineDescriptor *descriptor = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
		descriptor.vertexFunction = vertex_function;
		descriptor.fragmentFunction = fragment_function;
		descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
		if (pipeline == nil) {
			if (error != nil) Debug(driver, 0, "iOS Metal: pipeline creation failed: {}", [[error localizedDescription] UTF8String]);
			[vertex_function release];
			[fragment_function release];
			[fragment_function_indexed release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		/* 8bpp indexed colour pipeline. */
		MTLRenderPipelineDescriptor *descriptor_indexed = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
		descriptor_indexed.vertexFunction = vertex_function;
		descriptor_indexed.fragmentFunction = fragment_function_indexed;
		descriptor_indexed.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		id<MTLRenderPipelineState> pipeline_indexed = [device newRenderPipelineStateWithDescriptor:descriptor_indexed error:&error];
		if (pipeline_indexed == nil) {
			if (error != nil) Debug(driver, 0, "iOS Metal: indexed pipeline creation failed: {}", [[error localizedDescription] UTF8String]);
			[pipeline release];
			[vertex_function release];
			[fragment_function release];
			[fragment_function_indexed release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		/* 1D palette texture (256 BGRA entries) for 8bpp indexed mode. */
		MTLTextureDescriptor *pal_desc = [[[MTLTextureDescriptor alloc] init] autorelease];
		pal_desc.textureType = MTLTextureType1D;
		pal_desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
		pal_desc.width = 256;
		pal_desc.storageMode = MTLStorageModeShared;
		pal_desc.usage = MTLTextureUsageShaderRead;

		id<MTLTexture> palette_texture = [device newTextureWithDescriptor:pal_desc];
		if (palette_texture == nil) {
			[pipeline_indexed release];
			[pipeline release];
			[vertex_function release];
			[fragment_function release];
			[fragment_function_indexed release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		[vertex_function release];
		[fragment_function release];
		[fragment_function_indexed release];
		[library release];

		this->metal_queue = queue;
		this->metal_pipeline = pipeline;
		this->metal_pipeline_indexed = pipeline_indexed;
		this->metal_palette_texture = palette_texture;
	});

	return ok;
}

bool VideoDriver_iOS_Metal::StartDisplayLink()
{
	__block bool ok = true;

	RunOnMainThreadSync(^{
		if (this->display_link != nullptr) return;

		OTTD_iOSDisplayLinkTarget *target = [[OTTD_iOSDisplayLinkTarget alloc] init];
		target->driver = this;

		UIScreen *screen = (UIScreen *)this->active_screen;
		if (screen == nil) screen = PickPreferredScreen();

		CADisplayLink *display_link = nil;
		if (screen != nil && [screen respondsToSelector:@selector(displayLinkWithTarget:selector:)]) {
			display_link = [screen displayLinkWithTarget:target selector:@selector(onDisplayLink:)];
		}
		if (display_link == nil) {
			display_link = [CADisplayLink displayLinkWithTarget:target selector:@selector(onDisplayLink:)];
		}
		if (display_link == nil) {
			[target release];
			ok = false;
			return;
		}

		int max_fps = 120;
		if (screen != nil && [screen respondsToSelector:@selector(maximumFramesPerSecond)]) {
			max_fps = std::max(10, static_cast<int>(screen.maximumFramesPerSecond));
		}
		int target_fps = Clamp(_settings_client.gui.refresh_rate, 10, max_fps);
		if ([display_link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
			display_link.preferredFramesPerSecond = target_fps;
		}

		[display_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

		this->display_link_target = target;
		this->display_link = [display_link retain];
	});

	return ok;
}

void VideoDriver_iOS_Metal::StopDisplayLink()
{
	RunOnMainThreadSync(^{
		CADisplayLink *display_link = (CADisplayLink *)this->display_link;
		if (display_link != nil) {
			[display_link invalidate];
			[display_link release];
		}
		this->display_link = nullptr;

		OTTD_iOSDisplayLinkTarget *target = (OTTD_iOSDisplayLinkTarget *)this->display_link_target;
		if (target != nil) {
			target->driver = nullptr;
			[target release];
		}
		this->display_link_target = nullptr;
	});
}

void VideoDriver_iOS_Metal::DestroyMetalResources()
{
	id<MTLTexture> texture = (id<MTLTexture>)this->metal_texture;
	if (texture != nil) [texture release];
	this->metal_texture = nullptr;

	id<MTLTexture> palette_texture = (id<MTLTexture>)this->metal_palette_texture;
	if (palette_texture != nil) [palette_texture release];
	this->metal_palette_texture = nullptr;

	id<MTLRenderPipelineState> pipeline = (id<MTLRenderPipelineState>)this->metal_pipeline;
	if (pipeline != nil) [pipeline release];
	this->metal_pipeline = nullptr;

	id<MTLRenderPipelineState> pipeline_indexed = (id<MTLRenderPipelineState>)this->metal_pipeline_indexed;
	if (pipeline_indexed != nil) [pipeline_indexed release];
	this->metal_pipeline_indexed = nullptr;

	id<MTLCommandQueue> queue = (id<MTLCommandQueue>)this->metal_queue;
	if (queue != nil) [queue release];
	this->metal_queue = nullptr;

	free(this->pixel_buffer);
	this->pixel_buffer = nullptr;
	this->vid_w = 0;
	this->vid_h = 0;
	this->dirty_rect = {};
	_screen.dst_ptr = nullptr;
}

void VideoDriver_iOS_Metal::TeardownContextAndView()
{
	RunOnMainThreadSync(^{
		OTTDMetalView *proxy = (OTTDMetalView *)this->input_proxy_view;
		if (proxy != nil) {
			[proxy setDriver:nullptr];
			[proxy removeFromSuperview];
			[proxy release];
		}
		this->input_proxy_view = nullptr;

		this->DestroyMetalResources();

		UIView *view = (UIView *)this->metal_view;
		if (view != nil) {
			[view removeFromSuperview];
			[view release];
		}
		this->metal_view = nullptr;

		CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
		if (layer != nil) [layer release];
		this->metal_layer = nullptr;

		id<MTLDevice> device = (id<MTLDevice>)this->metal_device;
		if (device != nil) [device release];
		this->metal_device = nullptr;

		UIViewController *root = (UIViewController *)this->root_controller;
		OTTDViewController *ottd_root = (OTTDViewController *)root;
		if (ottd_root != nil) ottd_root->driver = nullptr;
		if (root != nil) [root release];
		this->root_controller = nullptr;

			UIWindow *window = (UIWindow *)this->ui_window;
			if (window != nil) {
				window.rootViewController = nil;
				window.hidden = YES;
				[window release];
			}
		this->ui_window = nullptr;

		UIScreen *screen = (UIScreen *)this->active_screen;
		if (screen != nil) [screen release];
		this->active_screen = nullptr;
		this->using_external_screen = false;
	});
}

bool VideoDriver_iOS_Metal::AllocateBackingStore([[maybe_unused]] int w, [[maybe_unused]] int h, bool force)
{
	__block bool changed = false;
	__block bool ok = true;

	RunOnMainThreadSync(^{
		UIView *view = (UIView *)this->metal_view;
		CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
		id<MTLDevice> device = (id<MTLDevice>)this->metal_device;
		if (view == nil || layer == nil || device == nil) {
			ok = false;
			return;
		}

		CGFloat scale = view.contentScaleFactor;
		CGSize bounds = view.bounds.size;

		/* view.bounds may be zero if UIKit has not completed its first layout pass yet.
		 * Fall back to the screen's native pixel size so we never allocate a 1×1 buffer. */
		if (bounds.width < 1.0 || bounds.height < 1.0) {
			UIScreen *screen = (UIScreen *)this->active_screen;
			if (screen == nil) screen = PickPreferredScreen();
			CGSize pixel_size = GetPixelSizeForScreen(screen);
			bounds = pixel_size;
			scale = 1.0; /* bounds are already in pixels */
		}

		CGSize drawable_size{};
		if (this->using_external_screen) {
			UIScreen *screen = (UIScreen *)this->active_screen;
			if (screen == nil) screen = PickPreferredScreen();
			CGSize pixel_size = GetPixelSizeForScreen(screen);
			drawable_size = CGSizeMake(std::max(1.0, pixel_size.width), std::max(1.0, pixel_size.height));
		} else {
			drawable_size = CGSizeMake(std::max(1.0, bounds.width * scale), std::max(1.0, bounds.height * scale));
		}
		layer.drawableSize = drawable_size;

		int dw = (int)drawable_size.width;
		int dh = (int)drawable_size.height;

		if (dw <= 0 || dh <= 0) {
			ok = false;
			return;
		}

		if (!force && dw == this->vid_w && dh == this->vid_h && this->pixel_buffer != nullptr) {
			return;
		}

		int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

		if (bpp != 8 && bpp != 32) {
			ok = false;
			return;
		}

		free(this->pixel_buffer);
		this->pixel_buffer = nullptr;

		size_t pixel_count = static_cast<size_t>(dw) * static_cast<size_t>(dh);
		this->pixel_buffer = static_cast<uint8_t *>(calloc(pixel_count, bpp == 8 ? 1u : 4u));
		if (this->pixel_buffer == nullptr) {
			ok = false;
			return;
		}

		id<MTLTexture> old_texture = (id<MTLTexture>)this->metal_texture;
		if (old_texture != nil) {
			[old_texture release];
			this->metal_texture = nullptr;
		}

		/* 8bpp: R8Uint index texture; 32bpp: direct BGRA texture. */
		MTLPixelFormat pixel_format = (bpp == 8) ? MTLPixelFormatR8Uint : MTLPixelFormatBGRA8Unorm;
		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixel_format width:(NSUInteger)dw height:(NSUInteger)dh mipmapped:NO];
		descriptor.storageMode = MTLStorageModeShared;
		descriptor.usage = MTLTextureUsageShaderRead;

		id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
		if (texture == nil) {
			ok = false;
			return;
		}

		this->metal_texture = texture;
		this->vid_w = dw;
		this->vid_h = dh;
		this->dirty_rect = {};

		_screen.width = dw;
		_screen.height = dh;
		_screen.pitch = dw;
		_screen.dst_ptr = this->pixel_buffer;

		CopyPalette(this->local_palette, true);
		changed = true;
	});

	if (!ok) return false;

	if (changed) {
		BlitterFactory::GetCurrentBlitter()->PostResize();
		GameSizeChanged();
		MarkWholeScreenDirty();
	}

	return changed;
}

std::optional<std::string_view> VideoDriver_iOS_Metal::Start([[maybe_unused]] const StringList &param)
{
	this->allow_tick.store(false, std::memory_order_release);

	int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

	if (bpp != 8 && bpp != 32) {
		return "The iOS Metal video driver only supports 8 and 32 bpp.";
	}

	this->is_game_threaded = false;
	this->UpdateAutoResolution();
	_fullscreen = true;

	if (!this->SetupContextAndView()) {
		this->Stop();
		return "Failed to initialize iOS Metal view";
	}

	/* iOS runs fullscreen; use the active screen's native size at startup. */
	Dimension screen_size = this->GetScreenSize();
	_resolutions.clear();
	_resolutions.push_back(screen_size);
	_cur_resolution = screen_size;
	Debug(driver, 1, "iOS Metal: startup resolution {}x{}", _cur_resolution.width, _cur_resolution.height);

	if (!this->InitMetalPipeline()) {
		this->Stop();
		return "Failed to initialize Metal pipeline";
	}

	if (!this->AllocateBackingStore(_cur_resolution.width, _cur_resolution.height, true) || this->pixel_buffer == nullptr) {
		this->Stop();
		return "Failed to allocate iOS Metal backing store";
	}

	this->RegisterScreenNotifications();

	if (!this->StartDisplayLink()) {
		this->Stop();
		return "Failed to start iOS display link";
	}

	auto now = std::chrono::steady_clock::now();
	this->next_game_tick = now;
	this->next_draw_tick = now;

	this->driver_info = this->using_external_screen ? "ios-metal (Metal, external display)" : "ios-metal (Metal)";
	return std::nullopt;
}

void VideoDriver_iOS_Metal::Stop()
{
	this->UnregisterScreenNotifications();
	this->StopDisplayLink();
	this->TeardownContextAndView();
}

void VideoDriver_iOS_Metal::MainLoop()
{
	this->allow_tick.store(true, std::memory_order_release);
	while (!_exit_game) {
		std::this_thread::sleep_for(std::chrono::milliseconds(20));
	}
	this->allow_tick.store(false, std::memory_order_release);
}

void VideoDriver_iOS_Metal::OnDisplayFrame()
{
	if (_exit_game) return;
	if (!this->allow_tick.load(std::memory_order_acquire)) return;
	this->Tick();
}

static bool IsNonTextEditBoxKey(uint keycode)
{
	uint base = keycode & ~WKC_SPECIAL_KEYS;

	switch (base) {
		case WKC_ESC:
		case WKC_BACKSPACE:
		case WKC_INSERT:
		case WKC_DELETE:
		case WKC_PAGEUP:
		case WKC_PAGEDOWN:
		case WKC_END:
		case WKC_HOME:
		case WKC_LEFT:
		case WKC_UP:
		case WKC_RIGHT:
		case WKC_DOWN:
		case WKC_RETURN:
		case WKC_TAB:
		case WKC_NUM_ENTER:
			return true;

		default:
			break;
	}

	if (base >= WKC_F1 && base <= WKC_F12) return true;
	return (keycode & (WKC_META | WKC_CTRL | WKC_ALT)) != 0;
}

void VideoDriver_iOS_Metal::OnHardwareModifierState(bool command_down, bool shift_down, bool alt_down)
{
	this->command_down = command_down;
	this->shift_down = shift_down;
	this->alt_down = alt_down;
}

void VideoDriver_iOS_Metal::OnHardwareKeyDown(uint keycode, char32_t character, std::string_view text)
{
	uint base = keycode & ~WKC_SPECIAL_KEYS;
	if (base == WKC_NONE && text.empty()) {
		if ((keycode & (WKC_SHIFT | WKC_CTRL | WKC_ALT | WKC_META)) == 0) {
			Debug(driver, 4, "iOS keyboard: ignored unmapped key event");
		}
		return;
	}

	switch (base) {
		case WKC_TAB:
			this->tab_down = true;
			break;
		case WKC_LEFT:
			this->directional_keys |= 1;
			break;
		case WKC_UP:
			this->directional_keys |= 2;
			break;
		case WKC_RIGHT:
			this->directional_keys |= 4;
			break;
		case WKC_DOWN:
			this->directional_keys |= 8;
			break;
		default:
			break;
	}

	if (!this->edit_box_focused || IsNonTextEditBoxKey(keycode) || text.empty()) {
		HandleKeypress(keycode, character);
		return;
	}

	if (base == WKC_BACKQUOTE && FocusedWindowIsConsole()) {
		HandleKeypress(keycode, character != WKC_NONE ? character : FirstUtf8CodePoint(text));
		return;
	}

	HandleTextInput(text);
}

void VideoDriver_iOS_Metal::OnHardwareKeyUp(uint keycode)
{
	uint base = keycode & ~WKC_SPECIAL_KEYS;

	switch (base) {
		case WKC_TAB:
			this->tab_down = false;
			break;
		case WKC_LEFT:
			this->directional_keys &= ~1;
			break;
		case WKC_UP:
			this->directional_keys &= ~2;
			break;
		case WKC_RIGHT:
			this->directional_keys &= ~4;
			break;
		case WKC_DOWN:
			this->directional_keys &= ~8;
			break;
		default:
			break;
	}
}

void VideoDriver_iOS_Metal::InputLoop()
{
	bool old_ctrl_pressed = _ctrl_pressed;

	_ctrl_pressed = this->command_down;
	_shift_pressed = this->shift_down;

	this->fast_forward_key_pressed = this->tab_down && !this->alt_down;
	_dirkeys = this->directional_keys;

	if (old_ctrl_pressed != _ctrl_pressed) HandleCtrlChanged();
}

void VideoDriver_iOS_Metal::EditBoxGainedFocus()
{
	this->edit_box_focused = true;
}

void VideoDriver_iOS_Metal::EditBoxLostFocus()
{
	this->edit_box_focused = false;
}

void VideoDriver_iOS_Metal::MakeDirty(int left, int top, int width, int height)
{
	Rect r = {left, top, left + width, top + height};
	this->dirty_rect = BoundingRect(this->dirty_rect, r);
}

void VideoDriver_iOS_Metal::CheckPaletteAnim()
{
	if (!CopyPalette(this->local_palette)) return;
	this->MakeDirty(0, 0, _screen.width, _screen.height);
}

bool VideoDriver_iOS_Metal::LockVideoBuffer()
{
	if (this->buffer_locked) return false;
	this->buffer_locked = true;
	_screen.dst_ptr = this->GetVideoPointer();
	assert(_screen.dst_ptr != nullptr);
	return true;
}

void VideoDriver_iOS_Metal::UnlockVideoBuffer()
{
	if (_screen.dst_ptr != nullptr) {
		this->ReleaseVideoPointer();
		_screen.dst_ptr = nullptr;
	}
	this->buffer_locked = false;
}

void *VideoDriver_iOS_Metal::GetVideoPointer()
{
	return this->pixel_buffer;
}

void VideoDriver_iOS_Metal::ReleaseVideoPointer()
{
}

void VideoDriver_iOS_Metal::Paint()
{
	PerformanceMeasurer framerate(PFE_VIDEO);

	if (IsEmptyRect(this->dirty_rect) && this->local_palette.count_dirty == 0) return;
	if (this->pixel_buffer == nullptr) return;

	bool palette_dirty = (this->local_palette.count_dirty != 0);
	if (palette_dirty) {
		Blitter *blitter = BlitterFactory::GetCurrentBlitter();
		switch (blitter->UsePaletteAnimation()) {
			case Blitter::PaletteAnimation::VideoBackend:
				break;

			case Blitter::PaletteAnimation::Blitter:
				blitter->PaletteAnimate(this->local_palette);
				break;

			case Blitter::PaletteAnimation::None:
				break;

			default:
				NOT_REACHED();
		}
		this->local_palette.count_dirty = 0;
	}

	int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

	RunOnMainThreadSync(^{
		CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
		id<MTLCommandQueue> queue = (id<MTLCommandQueue>)this->metal_queue;
		id<MTLTexture> texture = (id<MTLTexture>)this->metal_texture;
		if (layer == nil || queue == nil || texture == nil) return;

		id<MTLRenderPipelineState> active_pipeline;
		MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)this->vid_w, (NSUInteger)this->vid_h);

		if (bpp == 8) {
			/* Upload raw 8bpp indices (4x less data than RGBA). */
			[texture replaceRegion:region mipmapLevel:0 withBytes:this->pixel_buffer bytesPerRow:(NSUInteger)this->vid_w];

			/* Upload palette only when it changed. */
			id<MTLTexture> palette_texture = (id<MTLTexture>)this->metal_palette_texture;
			if (palette_dirty && palette_texture != nil) {
				[palette_texture replaceRegion:MTLRegionMake1D(0, 256) mipmapLevel:0 withBytes:this->local_palette.palette bytesPerRow:0];
			}

			active_pipeline = (id<MTLRenderPipelineState>)this->metal_pipeline_indexed;
		} else {
			/* Upload 32bpp BGRA pixels directly — no intermediate copy needed. */
			[texture replaceRegion:region mipmapLevel:0 withBytes:this->pixel_buffer bytesPerRow:(NSUInteger)this->vid_w * 4];
			active_pipeline = (id<MTLRenderPipelineState>)this->metal_pipeline;
		}

		if (active_pipeline == nil) return;

		id<CAMetalDrawable> drawable = [layer nextDrawable];
		if (drawable == nil) return;

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = drawable.texture;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

		id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
		if (command_buffer == nil) return;

		id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
		if (encoder == nil) return;

		[encoder setRenderPipelineState:active_pipeline];
		[encoder setFragmentTexture:texture atIndex:0];
		if (bpp == 8) {
			id<MTLTexture> palette_texture = (id<MTLTexture>)this->metal_palette_texture;
			[encoder setFragmentTexture:palette_texture atIndex:1];
		}
		[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
		[encoder endEncoding];

		[command_buffer presentDrawable:drawable];
		[command_buffer commit];
	});

	this->dirty_rect = {};
}

bool VideoDriver_iOS_Metal::ChangeResolution(int w, int h)
{
	_cur_resolution.width = static_cast<uint>(std::max(w, 64));
	_cur_resolution.height = static_cast<uint>(std::max(h, 64));
	return this->AllocateBackingStore(w, h, true) || this->pixel_buffer != nullptr;
}

bool VideoDriver_iOS_Metal::ToggleFullscreen(bool fullscreen)
{
	_fullscreen = true;
	return fullscreen;
}

bool VideoDriver_iOS_Metal::AfterBlitterChange()
{
	return this->AllocateBackingStore(_screen.width, _screen.height, true) || this->pixel_buffer != nullptr;
}

bool VideoDriver_iOS_Metal::UseSystemCursor()
{
	return !this->using_external_screen;
}

void VideoDriver_iOS_Metal::SetScreensaverInhibited(bool inhibited)
{
	RunOnMainThreadSync(^{
		[UIApplication sharedApplication].idleTimerDisabled = inhibited;
	});
}

std::vector<int> VideoDriver_iOS_Metal::GetListOfMonitorRefreshRates()
{
	__block int fps = 60;
	RunOnMainThreadSync(^{
		UIScreen *screen = (UIScreen *)this->active_screen;
		if (screen == nil) screen = PickPreferredScreen();
		if ([screen respondsToSelector:@selector(maximumFramesPerSecond)]) {
			fps = static_cast<int>(screen.maximumFramesPerSecond);
		}
	});
	return { fps };
}

void VideoDriver_iOS_Metal::NotifySizeChanged()
{
	if (this->AllocateBackingStore(0, 0, false)) {
		_cur_resolution.width = _screen.width;
		_cur_resolution.height = _screen.height;
	}
}

#include "../safeguards.h"
