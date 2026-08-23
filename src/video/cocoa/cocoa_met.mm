/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/**
 * @file cocoa_met.mm Code related to the cocoa Metal video driver.
 *
 * The game blits into a CPU-side buffer which is uploaded to a texture and
 * drawn as a single full-screen quad. This mirrors the iOS Metal backend and
 * keeps the driver independent of the OpenGL backend's GPU-side buffers.
 */

#if (defined(WITH_COCOA) && defined(WITH_COCOA_METAL)) || defined(DOXYGEN_API)

#include "../../stdafx.h"
#include "../../os/macosx/macos.h"

#include "../../os/macosx/macos_objective_c.h"
#include "../../openttd.h"
#include "../../debug.h"
#include "../../core/geometry_func.hpp"
#include "../../core/math_func.hpp"
#include "cocoa_met.h"
#include "cocoa_wnd.h"
#include "../../blitter/factory.hpp"
#include "../../gfx_func.h"
#include "../../framerate_type.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "../../safeguards.h"

static Palette _local_palette; ///< Current palette to use for drawing.

/** Shader pair for the two blitter depths; shared with the iOS Metal backend. */
static const char *_cocoa_metal_shader_src = R"(
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

/** Storage for instance of the FVideoDriver_CocoaMetal class. */
static FVideoDriver_CocoaMetal iFVideoDriver_CocoaMetal;

/** NSView backed by a CAMetalLayer. */
@interface OTTD_MetalView : NSView
@end

@implementation OTTD_MetalView

+ (Class)layerClass
{
	return [CAMetalLayer class];
}

- (CALayer *)makeBackingLayer
{
	return [CAMetalLayer layer];
}

- (instancetype)initWithFrame:(NSRect)frame
{
	if (self = [super initWithFrame:frame]) {
		self.wantsLayer = YES;
		self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
	}
	return self;
}

/* The game draws every frame in full; never let AppKit ask us to draw. */
- (BOOL)isOpaque { return YES; }

@end


std::optional<std::string_view> VideoDriver_CocoaMetal::AllocateMetalResources()
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	if (dev == nil) return "No Metal device available";

	id<MTLCommandQueue> q = [dev newCommandQueue];
	if (q == nil) {
		[dev release];
		return "Could not create a Metal command queue";
	}

	NSError *error = nil;
	NSString *source = [NSString stringWithUTF8String:_cocoa_metal_shader_src];
	id<MTLLibrary> library = [dev newLibraryWithSource:source options:nil error:&error];
	if (library == nil) {
		if (error != nil) Debug(driver, 0, "Cocoa Metal: shader compile failed: {}", [[error localizedDescription] UTF8String]);
		[q release];
		[dev release];
		return "Could not compile the Metal shaders";
	}

	id<MTLFunction> vs = [library newFunctionWithName:@"vs_main"];
	id<MTLFunction> fs = [library newFunctionWithName:@"fs_main"];
	id<MTLFunction> fs_indexed = [library newFunctionWithName:@"fs_main_indexed"];

	std::optional<std::string_view> err;
	id<MTLRenderPipelineState> pl = nil;
	id<MTLRenderPipelineState> pl_indexed = nil;

	if (vs == nil || fs == nil || fs_indexed == nil) {
		err = "Could not find the Metal shader entry points";
	} else {
		MTLRenderPipelineDescriptor *desc = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
		desc.vertexFunction = vs;
		desc.fragmentFunction = fs;
		desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
		pl = [dev newRenderPipelineStateWithDescriptor:desc error:&error];
		if (pl == nil) {
			if (error != nil) Debug(driver, 0, "Cocoa Metal: pipeline creation failed: {}", [[error localizedDescription] UTF8String]);
			err = "Could not create the Metal render pipeline";
		} else {
			MTLRenderPipelineDescriptor *desc_indexed = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
			desc_indexed.vertexFunction = vs;
			desc_indexed.fragmentFunction = fs_indexed;
			desc_indexed.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
			pl_indexed = [dev newRenderPipelineStateWithDescriptor:desc_indexed error:&error];
			if (pl_indexed == nil) {
				if (error != nil) Debug(driver, 0, "Cocoa Metal: indexed pipeline creation failed: {}", [[error localizedDescription] UTF8String]);
				err = "Could not create the indexed Metal render pipeline";
			}
		}
	}

	if (vs != nil) [vs release];
	if (fs != nil) [fs release];
	if (fs_indexed != nil) [fs_indexed release];
	[library release];

	if (err) {
		if (pl != nil) [pl release];
		[q release];
		[dev release];
		return err;
	}

	/* 1D palette texture used by the indexed path. */
	MTLTextureDescriptor *pal_desc = [[[MTLTextureDescriptor alloc] init] autorelease];
	pal_desc.textureType = MTLTextureType1D;
	pal_desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
	pal_desc.width = 256;
	pal_desc.storageMode = MTLStorageModeShared;
	pal_desc.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> pal = [dev newTextureWithDescriptor:pal_desc];
	if (pal == nil) {
		[pl_indexed release];
		[pl release];
		[q release];
		[dev release];
		return "Could not create the Metal palette texture";
	}

	this->device = dev;
	this->queue = q;
	this->pipeline = pl;
	this->pipeline_indexed = pl_indexed;
	this->palette_texture = pal;

	this->driver_info = this->GetName();
	this->driver_info += " (";
	this->driver_info += [[dev name] UTF8String];
	this->driver_info += ")";

	return std::nullopt;
}

void VideoDriver_CocoaMetal::ReleaseMetalResources()
{
	if (this->texture != nullptr) {
		[(id<MTLTexture>)this->texture release];
		this->texture = nullptr;
	}
	if (this->palette_texture != nullptr) {
		[(id<MTLTexture>)this->palette_texture release];
		this->palette_texture = nullptr;
	}
	if (this->pipeline_indexed != nullptr) {
		[(id<MTLRenderPipelineState>)this->pipeline_indexed release];
		this->pipeline_indexed = nullptr;
	}
	if (this->pipeline != nullptr) {
		[(id<MTLRenderPipelineState>)this->pipeline release];
		this->pipeline = nullptr;
	}
	if (this->queue != nullptr) {
		[(id<MTLCommandQueue>)this->queue release];
		this->queue = nullptr;
	}
	if (this->device != nullptr) {
		[(id<MTLDevice>)this->device release];
		this->device = nullptr;
	}

	this->pixel_buffer.reset();
	this->vid_w = 0;
	this->vid_h = 0;

	/* The layer belongs to the view and is released with it. */
	this->metal_layer = nullptr;
}

std::optional<std::string_view> VideoDriver_CocoaMetal::Start(const StringList &param)
{
	auto err = this->Initialize();
	if (err) return err;

	int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();
	if (bpp != 8 && bpp != 32) {
		this->Stop();
		return "The cocoa Metal subdriver only supports 8 and 32 bpp.";
	}

	err = this->AllocateMetalResources();
	if (err) {
		this->Stop();
		return err;
	}

	bool fullscreen = _fullscreen;
	if (!this->MakeWindow(_cur_resolution.width, _cur_resolution.height)) {
		this->Stop();
		return "Could not create window";
	}

	this->AllocateBackingStore(true);

	if (fullscreen) this->ToggleFullscreen(fullscreen);

	this->GameSizeChanged();
	this->UpdateVideoModes();
	MarkWholeScreenDirty();

	this->is_game_threaded = !GetDriverParamBool(param, "no_threads") && !GetDriverParamBool(param, "no_thread");

	return std::nullopt;
}

void VideoDriver_CocoaMetal::Stop()
{
	this->ReleaseMetalResources();
	this->VideoDriver_Cocoa::Stop();
}

NSView *VideoDriver_CocoaMetal::AllocateDrawView()
{
	OTTD_MetalView *view = [[OTTD_MetalView alloc] initWithFrame:this->cocoaview.bounds];

	CAMetalLayer *layer = (CAMetalLayer *)view.layer;
	layer.device = (id<MTLDevice>)this->device;
	layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	layer.framebufferOnly = YES;
	this->metal_layer = layer;

	return view;
}

bool VideoDriver_CocoaMetal::ResizeBackingStore(int w, int h, bool force)
{
	if (w < 1 || h < 1) return false;

	int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();
	if (bpp != 8 && bpp != 32) return false;

	if (!force && w == this->vid_w && h == this->vid_h && bpp == this->buffer_depth && this->pixel_buffer != nullptr) {
		return true;
	}

	id<MTLDevice> dev = (id<MTLDevice>)this->device;
	if (dev == nil) return false;

	MTLPixelFormat format = (bpp == 8) ? MTLPixelFormatR8Uint : MTLPixelFormatBGRA8Unorm;
	MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
		width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
	desc.storageMode = MTLStorageModeShared;
	desc.usage = MTLTextureUsageShaderRead;

	id<MTLTexture> tex = [dev newTextureWithDescriptor:desc];
	if (tex == nil) return false;

	size_t pixel_count = static_cast<size_t>(w) * static_cast<size_t>(h) * (bpp == 8 ? 1u : 4u);
	auto buffer = std::make_unique<uint8_t[]>(pixel_count);

	if (this->texture != nullptr) [(id<MTLTexture>)this->texture release];

	this->texture = tex;
	this->pixel_buffer = std::move(buffer);
	this->vid_w = w;
	this->vid_h = h;
	this->buffer_depth = bpp;

	return true;
}

void VideoDriver_CocoaMetal::AllocateBackingStore(bool force)
{
	if (this->window == nil || this->setup) return;

	CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
	if (layer == nil) return;

	NSRect frame = [this->cocoaview getRealRect:[this->cocoaview frame]];
	int w = std::max(1, static_cast<int>(frame.size.width));
	int h = std::max(1, static_cast<int>(frame.size.height));

	CGFloat scale = [this->cocoaview getContentsScale];
	layer.contentsScale = scale > 0.0 ? scale : 1.0;
	layer.drawableSize = CGSizeMake(w, h);

	if (!this->ResizeBackingStore(w, h, force)) return;

	_screen.width = this->vid_w;
	_screen.height = this->vid_h;
	_screen.pitch = this->vid_w;
	_screen.dst_ptr = this->buffer_locked ? this->GetVideoPointer() : nullptr;

	this->dirty_rect = {};

	CopyPalette(_local_palette, true);

	/* Redraw screen */
	this->GameSizeChanged();
}

void *VideoDriver_CocoaMetal::GetVideoPointer()
{
	return this->pixel_buffer.get();
}

void VideoDriver_CocoaMetal::ReleaseVideoPointer()
{
	_screen.dst_ptr = nullptr;
}

void VideoDriver_CocoaMetal::Paint()
{
	PerformanceMeasurer framerate(PerformanceElement::Video);

	CAMetalLayer *layer = (CAMetalLayer *)this->metal_layer;
	id<MTLCommandQueue> queue = (id<MTLCommandQueue>)this->queue;
	id<MTLTexture> tex = (id<MTLTexture>)this->texture;
	if (layer == nil || queue == nil || tex == nil || this->pixel_buffer == nullptr) return;

	bool palette_dirty = CopyPalette(_local_palette);
	if (palette_dirty && this->buffer_depth == 8) {
		Blitter *blitter = BlitterFactory::GetCurrentBlitter();
		if (blitter->UsePaletteAnimation() == Blitter::PaletteAnimation::Blitter) {
			blitter->PaletteAnimate(_local_palette);
		}
	}

	id<MTLRenderPipelineState> active_pipeline;
	if (this->buffer_depth == 8) {
		/* Upload the palette indices as-is; the shader resolves the colour. */
		[tex replaceRegion:MTLRegionMake2D(0, 0, this->vid_w, this->vid_h) mipmapLevel:0
			withBytes:this->pixel_buffer.get() bytesPerRow:(NSUInteger)this->vid_w];

		id<MTLTexture> pal = (id<MTLTexture>)this->palette_texture;
		if (pal == nil) return;
		/* The palette is only 1 KiB, so upload it whole rather than tracking
		 * partial dirty ranges across texture rebuilds. */
		[pal replaceRegion:MTLRegionMake1D(0, 256) mipmapLevel:0 withBytes:_local_palette.palette bytesPerRow:0];
		active_pipeline = (id<MTLRenderPipelineState>)this->pipeline_indexed;
	} else {
		[tex replaceRegion:MTLRegionMake2D(0, 0, this->vid_w, this->vid_h) mipmapLevel:0
			withBytes:this->pixel_buffer.get() bytesPerRow:(NSUInteger)this->vid_w * 4];
		active_pipeline = (id<MTLRenderPipelineState>)this->pipeline;
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
	[encoder setFragmentTexture:tex atIndex:0];
	if (this->buffer_depth == 8) {
		[encoder setFragmentTexture:(id<MTLTexture>)this->palette_texture atIndex:1];
	}
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[encoder endEncoding];

	[command_buffer presentDrawable:drawable];
	[command_buffer commit];

	this->dirty_rect = {};
}

#endif /* WITH_COCOA */
