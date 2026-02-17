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
#include "../debug.h"
#include "../framerate_type.h"
#include "../gfx_func.h"
#include "../openttd.h"
#include "../settings_type.h"
#include "../window_func.h"
#include "ios_glkit_v.h"

#include <dispatch/dispatch.h>

static FVideoDriver_iOS_Metal iFVideoDriver_iOS_Metal;
static FVideoDriver_iOS_MetalCompatGLKit iFVideoDriver_iOS_MetalCompatGLKit;
static FVideoDriver_iOS_MetalCompatGLES iFVideoDriver_iOS_MetalCompatGLES;
static FVideoDriver_iOS_MetalCompatSDL iFVideoDriver_iOS_MetalCompatSDL;

/** Minimal UIView subclass with CAMetalLayer backing and touch input. */
@interface OTTDMetalView : UIView {
@private
	CGPoint _single_touch_prev;   ///< Previous single-touch location in view points.
	CGPoint _pan_prev_centroid;   ///< Previous two-finger centroid in view points.
	bool    _in_two_finger_pan;   ///< Whether we are currently in two-finger pan mode.
}
@end

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

@implementation OTTDMetalView

+ (Class)layerClass
{
	return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.multipleTouchEnabled = YES;
		_in_two_finger_pan = false;
		_single_touch_prev = CGPointZero;
		_pan_prev_centroid = CGPointZero;

		/* Long press (0.5 s) acts as a right-click to open context menus. */
		UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
			initWithTarget:self action:@selector(_ottd_longPress:)];
		lp.minimumPressDuration = 0.5;
		[self addGestureRecognizer:lp];
		[lp release];
	}
	return self;
}

/** Convert a view-space point to game pixel coordinates. */
- (CGPoint)_pixelPoint:(CGPoint)pt
{
	CGFloat s = self.contentScaleFactor;
	return CGPointMake(pt.x * s, pt.y * s);
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

		_left_button_down = true;
		_left_button_clicked = true;
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	NSSet<UITouch *> *all = event.allTouches;
	CGFloat scale = self.contentScaleFactor;

	if (_in_two_finger_pan) {
		CGPoint cen = CentroidOfActiveTouches(all, self);
		if (_cursor.fix_at) {
			/* Cursor is locked (e.g. during map drag); supply relative delta. */
			int dx = (int)((cen.x - _pan_prev_centroid.x) * scale);
			int dy = (int)((cen.y - _pan_prev_centroid.y) * scale);
			_cursor.UpdateCursorPositionRelative(dx, dy);
		} else {
			CGPoint px = [self _pixelPoint:cen];
			_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		}
		_pan_prev_centroid = cen;
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
			int dx = (int)((pt.x - _single_touch_prev.x) * scale);
			int dy = (int)((pt.y - _single_touch_prev.y) * scale);
			_cursor.UpdateCursorPositionRelative(dx, dy);
		} else {
			CGPoint px = [self _pixelPoint:pt];
			_cursor.UpdateCursorPosition((int)px.x, (int)px.y);
		}
		_single_touch_prev = pt;
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
			_left_button_down = false;
			_left_button_clicked = false;
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

static void RunOnMainThreadSync(dispatch_block_t block)
{
	if ([NSThread isMainThread]) {
		block();
		return;
	}
	dispatch_sync(dispatch_get_main_queue(), block);
}

/* Fullscreen textured quad shader for BGRA8 texture. */
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

	fragment half4 fs_main(VSOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) {
		constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
		return tex.sample(s, in.uv);
	}
)";

Dimension VideoDriver_iOS_Metal::GetScreenSize() const
{
	__block Dimension result = VideoDriver::GetScreenSize();

	RunOnMainThreadSync(^{
		UIScreen *screen = [UIScreen mainScreen];
		CGRect native = screen.nativeBounds;
		if (native.size.width > 0.0 && native.size.height > 0.0) {
			result = { static_cast<uint>(native.size.width), static_cast<uint>(native.size.height) };
			return;
		}

		CGRect bounds = screen.bounds;
		CGFloat scale = screen.scale;
		result = {
			static_cast<uint>(bounds.size.width * scale),
			static_cast<uint>(bounds.size.height * scale)
		};
	});

	return result;
}

bool VideoDriver_iOS_Metal::SetupContextAndView()
{
	__block bool ok = true;


	RunOnMainThreadSync(^{
		UIApplication *app = [UIApplication sharedApplication];
		UIWindow *window = nil;
		NSArray *windows = app.windows;
		if (windows.count > 0) window = windows[0];

		if (window == nil) {
			window = [[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds] autorelease];
		}

		UIViewController *root = window.rootViewController;
		if (root == nil) {
			root = [[[UIViewController alloc] init] autorelease];
			window.rootViewController = root;
		}

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

		view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

		CGFloat scale = [UIScreen mainScreen].scale;
		view.contentScaleFactor = scale;

		CAMetalLayer *layer = (CAMetalLayer *)view.layer;
		layer.device = device;
		layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		layer.framebufferOnly = YES;
		layer.contentsScale = scale;
		CGSize drawable_size = CGSizeMake(std::max(1.0, view.bounds.size.width * scale), std::max(1.0, view.bounds.size.height * scale));
		layer.drawableSize = drawable_size;

		[root.view addSubview:view];
		[window makeKeyAndVisible];

		this->ui_window = [window retain];
		this->root_controller = [root retain];
		this->metal_view = [view retain];
		this->metal_layer = [layer retain];
		this->metal_device = [device retain];

	});

	return ok;
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
			[queue release];
			ok = false;
			return;
		}

		id<MTLFunction> vertex_function = [library newFunctionWithName:@"vs_main"];
		id<MTLFunction> fragment_function = [library newFunctionWithName:@"fs_main"];
		if (vertex_function == nil || fragment_function == nil) {
			if (vertex_function != nil) [vertex_function release];
			if (fragment_function != nil) [fragment_function release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		MTLRenderPipelineDescriptor *descriptor = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
		descriptor.vertexFunction = vertex_function;
		descriptor.fragmentFunction = fragment_function;
		descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

		id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
		if (pipeline == nil) {
			[vertex_function release];
			[fragment_function release];
			[library release];
			[queue release];
			ok = false;
			return;
		}

		[vertex_function release];
		[fragment_function release];
		[library release];

		this->metal_queue = queue;
		this->metal_pipeline = pipeline;

	});

	return ok;
}

bool VideoDriver_iOS_Metal::StartDisplayLink()
{
	__block bool ok = true;


	RunOnMainThreadSync(^{
		if (this->display_link != nullptr) {
			return;
		}

		OTTD_iOSDisplayLinkTarget *target = [[OTTD_iOSDisplayLinkTarget alloc] init];
		target->driver = this;

		CADisplayLink *display_link = [CADisplayLink displayLinkWithTarget:target selector:@selector(onDisplayLink:)];
		if (display_link == nil) {
			[target release];
			ok = false;
			return;
		}

		int target_fps = Clamp(_settings_client.gui.refresh_rate, 10, 120);
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

	id<MTLRenderPipelineState> pipeline = (id<MTLRenderPipelineState>)this->metal_pipeline;
	if (pipeline != nil) [pipeline release];
	this->metal_pipeline = nullptr;

	id<MTLCommandQueue> queue = (id<MTLCommandQueue>)this->metal_queue;
	if (queue != nil) [queue release];
	this->metal_queue = nullptr;

	free(this->pixel_buffer);
	this->pixel_buffer = nullptr;
	free(this->rgba_buffer);
	this->rgba_buffer = nullptr;
	this->vid_w = 0;
	this->vid_h = 0;
	this->dirty_rect = {};
	_screen.dst_ptr = nullptr;
}

void VideoDriver_iOS_Metal::TeardownContextAndView()
{
	RunOnMainThreadSync(^{
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
		if (root != nil) [root release];
		this->root_controller = nullptr;

		UIWindow *window = (UIWindow *)this->ui_window;
		if (window != nil) [window release];
		this->ui_window = nullptr;
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

		CGSize drawable_size = CGSizeMake(std::max(1.0, bounds.width * scale), std::max(1.0, bounds.height * scale));
		layer.drawableSize = drawable_size;

		int dw = (int)drawable_size.width;
		int dh = (int)drawable_size.height;

		if (dw <= 0 || dh <= 0) {
			ok = false;
			return;
		}

		if (!force && dw == this->vid_w && dh == this->vid_h && this->pixel_buffer != nullptr && this->rgba_buffer != nullptr) {
			return;
		}

		int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

		if (bpp != 8 && bpp != 32) {
			ok = false;
			return;
		}

		free(this->pixel_buffer);
		this->pixel_buffer = nullptr;
		free(this->rgba_buffer);
		this->rgba_buffer = nullptr;

		size_t pixel_count = static_cast<size_t>(dw) * static_cast<size_t>(dh);
		this->pixel_buffer = static_cast<uint8_t *>(calloc(pixel_count, bpp == 8 ? 1u : 4u));
		this->rgba_buffer = static_cast<uint32_t *>(malloc(pixel_count * sizeof(uint32_t)));
		if (this->pixel_buffer == nullptr || this->rgba_buffer == nullptr) {
			ok = false;
			return;
		}

		id<MTLTexture> old_texture = (id<MTLTexture>)this->metal_texture;
		if (old_texture != nil) {
			[old_texture release];
			this->metal_texture = nullptr;
		}

		MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)dw height:(NSUInteger)dh mipmapped:NO];
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

	_resolutions.clear();
	Dimension screen_size = this->GetScreenSize();
	_resolutions.push_back(screen_size);

	if (!this->SetupContextAndView()) {
		this->Stop();
		return "Failed to initialize iOS Metal view";
	}

	if (!this->InitMetalPipeline()) {
		this->Stop();
		return "Failed to initialize Metal pipeline";
	}

	if (!this->AllocateBackingStore(_cur_resolution.width, _cur_resolution.height, true) || this->pixel_buffer == nullptr) {
		this->Stop();
		return "Failed to allocate iOS Metal backing store";
	}

	if (!this->StartDisplayLink()) {
		this->Stop();
		return "Failed to start iOS display link";
	}

	auto now = std::chrono::steady_clock::now();
	this->next_game_tick = now;
	this->next_draw_tick = now;

	this->driver_info = "ios-metal (Metal)";
	return std::nullopt;
}

void VideoDriver_iOS_Metal::Stop()
{
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

	if (IsEmptyRect(this->dirty_rect) && this->local_palette.count_dirty == 0) {
		return;
	}
	if (this->pixel_buffer == nullptr || this->rgba_buffer == nullptr) {
		return;
	}

	if (this->local_palette.count_dirty != 0) {
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
	size_t pixel_count = static_cast<size_t>(this->vid_w) * static_cast<size_t>(this->vid_h);

	if (bpp == 8) {
		const uint8_t *src = this->pixel_buffer;
		uint32_t *dst = this->rgba_buffer;
		for (size_t i = 0; i < pixel_count; i++) {
			uint8_t idx = src[i];
			const Colour &c = this->local_palette.palette[idx];
			dst[i] = 0xFF000000u | (static_cast<uint32_t>(c.r) << 16) | (static_cast<uint32_t>(c.g) << 8) | static_cast<uint32_t>(c.b);
		}
	} else {
		memcpy(this->rgba_buffer, this->pixel_buffer, pixel_count * sizeof(uint32_t));
	}

	RunOnMainThreadSync(^{
		CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
		id<MTLCommandQueue> queue = (id<MTLCommandQueue>)this->metal_queue;
		id<MTLRenderPipelineState> pipeline = (id<MTLRenderPipelineState>)this->metal_pipeline;
		id<MTLTexture> texture = (id<MTLTexture>)this->metal_texture;
		if (layer == nil || queue == nil || pipeline == nil || texture == nil) {
			return;
		}

		MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)this->vid_w, (NSUInteger)this->vid_h);
		[texture replaceRegion:region mipmapLevel:0 withBytes:this->rgba_buffer bytesPerRow:(NSUInteger)this->vid_w * 4];

		id<CAMetalDrawable> drawable = [layer nextDrawable];
		if (drawable == nil) {
			return;
		}

		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = drawable.texture;
		pass.colorAttachments[0].loadAction = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

		id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
		if (command_buffer == nil) {
			return;
		}

		id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:pass];
		if (encoder == nil) {
			return;
		}

		[encoder setRenderPipelineState:pipeline];
		[encoder setFragmentTexture:texture atIndex:0];
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
		UIScreen *screen = [UIScreen mainScreen];
		if ([screen respondsToSelector:@selector(maximumFramesPerSecond)]) {
			fps = static_cast<int>(screen.maximumFramesPerSecond);
		}
	});
	return { fps };
}

#include "../safeguards.h"
