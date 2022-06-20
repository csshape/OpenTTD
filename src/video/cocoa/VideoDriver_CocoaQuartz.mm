//
//  VideoDriver_CocoaQuartz.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 06/06/2022.
//

#include "../../stdafx.h"
#include "../../os/macosx/macos.h"

#define Rect  OTTDRect
#define Point OTTDPoint
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#undef Rect
#undef Point

#include "../../openttd.h"
#include "../../debug.h"
#include "../../core/geometry_func.hpp"
#include "../../core/math_func.hpp"

#include "../../blitter/factory.hpp"
#include "../../framerate_type.h"

#include "../../gfx_func.h"
#include "../../thread.h"
#include "../../core/random_func.hpp"
#include "../../progress.h"
#include "../../settings_type.h"
#include "../../window_func.h"
#include "../../window_gui.h"

#import "VideoDriver_CocoaQuartz.h"
#include "cocoa_wnd.h"

static Palette _local_palette; ///< Current palette to use for drawing.

/* Subclass of OTTD_CocoaView to fix Quartz rendering */
@interface OTTD_QuartzView : NSView {
    VideoDriver_CocoaQuartz *driver;
}
- (instancetype)initWithFrame:(NSRect)frameRect andDriver:(VideoDriver_CocoaQuartz *)drv;
@end

@implementation OTTD_QuartzView

- (instancetype)initWithFrame:(NSRect)frameRect andDriver:(VideoDriver_CocoaQuartz *)drv
{
    if (self = [ super initWithFrame:frameRect ]) {
        self->driver = drv;

        /* We manage our content updates ourselves. */
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        self.wantsLayer = YES;

        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.opaque = YES;
    }
    return self;
}

- (BOOL)acceptsFirstResponder
{
    return NO;
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    if (driver->cgcontext == nullptr) return;

    /* Set layer contents to our backing buffer, which avoids needless copying. */
    CGImageRef fullImage = CGBitmapContextCreateImage(driver->cgcontext);
    self.layer.contents = (__bridge id)fullImage;
    CGImageRelease(fullImage);
}

- (void)viewDidChangeBackingProperties
{
    [ super viewDidChangeBackingProperties ];

    self.layer.contentsScale = [ driver->cocoaview getContentsScale ];
}

@end


static FVideoDriver_CocoaQuartz iFVideoDriver_CocoaQuartz;

/** Clear buffer to opaque black. */
static void ClearWindowBuffer(uint32 *buffer, uint32 pitch, uint32 height)
{
    uint32 fill = Colour(0, 0, 0).data;
    for (uint32 y = 0; y < height; y++) {
        for (uint32 x = 0; x < pitch; x++) {
            buffer[y * pitch + x] = fill;
        }
    }
}

VideoDriver_CocoaQuartz::VideoDriver_CocoaQuartz()
{
    this->window_width  = 0;
    this->window_height = 0;
    this->window_pitch  = 0;
    this->buffer_depth  = 0;
    this->window_buffer = nullptr;
    this->pixel_buffer  = nullptr;

    this->cgcontext     = nullptr;
}

const char *VideoDriver_CocoaQuartz::Start(const StringList &param)
{
    const char *err = this->Initialize();
    if (err != nullptr) return err;

    int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();
    if (bpp != 8 && bpp != 32) {
        Stop();
        return "The cocoa quartz subdriver only supports 8 and 32 bpp.";
    }

    bool fullscreen = _fullscreen;
    if (!this->MakeWindow(_cur_resolution.width, _cur_resolution.height)) {
        Stop();
        return "Could not create window";
    }

    this->AllocateBackingStore(true);

    if (fullscreen) this->ToggleFullscreen(fullscreen);

    this->GameSizeChanged();
    this->UpdateVideoModes();

    this->is_game_threaded = !GetDriverParamBool(param, "no_threads") && !GetDriverParamBool(param, "no_thread");

    return nullptr;

}

void VideoDriver_CocoaQuartz::Stop()
{
    this->VideoDriver_Cocoa::Stop();

    CGContextRelease(this->cgcontext);

    free(this->window_buffer);
    free(this->pixel_buffer);
}

NSView *VideoDriver_CocoaQuartz::AllocateDrawView()
{
    return [ [ OTTD_QuartzView alloc ] initWithFrame:[ this->cocoaview bounds ] andDriver:this ];
}

/** Resize the window. */
void VideoDriver_CocoaQuartz::AllocateBackingStore(bool force)
{
    if (this->window == nil || this->cocoaview == nil || this->setup) return;

    this->UpdatePalette(0, 256);

    NSRect newframe = [ this->cocoaview getRealRect:[ this->cocoaview frame ] ];

    this->window_width = (int)newframe.size.width;
    this->window_height = (int)newframe.size.height;
    this->window_pitch = Align(this->window_width, 16 / sizeof(uint32)); // Quartz likes lines that are multiple of 16-byte.
    this->buffer_depth = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

    /* Create Core Graphics Context */
    free(this->window_buffer);
    this->window_buffer = malloc(this->window_pitch * this->window_height * sizeof(uint32));
    /* Initialize with opaque black. */
    ClearWindowBuffer((uint32 *)this->window_buffer, this->window_pitch, this->window_height);

    CGContextRelease(this->cgcontext);
    this->cgcontext = CGBitmapContextCreate(
        this->window_buffer,       // data
        this->window_width,        // width
        this->window_height,       // height
        8,                         // bits per component
        this->window_pitch * 4,    // bytes per row
        this->color_space,         // color space
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host
    );

    assert(this->cgcontext != NULL);
    CGContextSetShouldAntialias(this->cgcontext, FALSE);
    CGContextSetAllowsAntialiasing(this->cgcontext, FALSE);
    CGContextSetInterpolationQuality(this->cgcontext, kCGInterpolationNone);

    if (this->buffer_depth == 8) {
        free(this->pixel_buffer);
        this->pixel_buffer = malloc(this->window_width * this->window_height);
        if (this->pixel_buffer == nullptr) usererror("Out of memory allocating pixel buffer");
    } else {
        free(this->pixel_buffer);
        this->pixel_buffer = nullptr;
    }

    /* Tell the game that the resolution has changed */
    _screen.width   = this->window_width;
    _screen.height  = this->window_height;
    _screen.pitch   = this->buffer_depth == 8 ? this->window_width : this->window_pitch;
    _screen.dst_ptr = this->GetVideoPointer();

    /* Redraw screen */
    this->MakeDirty(0, 0, _screen.width, _screen.height);
    this->GameSizeChanged();
}

/**
 * This function copies 8bpp pixels from the screen buffer in 32bpp windowed mode.
 *
 * @param left The x coord for the left edge of the box to blit.
 * @param top The y coord for the top edge of the box to blit.
 * @param right The x coord for the right edge of the box to blit.
 * @param bottom The y coord for the bottom edge of the box to blit.
 */
void VideoDriver_CocoaQuartz::BlitIndexedToView32(int left, int top, int right, int bottom)
{
    const uint32 *pal   = this->palette;
    const uint8  *src   = (uint8*)this->pixel_buffer;
    uint32       *dst   = (uint32*)this->window_buffer;
    uint          width = this->window_width;
    uint          pitch = this->window_pitch;

    for (int y = top; y < bottom; y++) {
        for (int x = left; x < right; x++) {
            dst[y * pitch + x] = pal[src[y * width + x]];
        }
    }
}

/** Update the palette */
void VideoDriver_CocoaQuartz::UpdatePalette(uint first_color, uint num_colors)
{
    if (this->buffer_depth != 8) return;

    for (uint i = first_color; i < first_color + num_colors; i++) {
        uint32 clr = 0xff000000;
        clr |= (uint32)_local_palette.palette[i].r << 16;
        clr |= (uint32)_local_palette.palette[i].g << 8;
        clr |= (uint32)_local_palette.palette[i].b;
        this->palette[i] = clr;
    }

    this->MakeDirty(0, 0, _screen.width, _screen.height);
}

void VideoDriver_CocoaQuartz::CheckPaletteAnim()
{
    if (!CopyPalette(_local_palette)) return;

    Blitter *blitter = BlitterFactory::GetCurrentBlitter();

    switch (blitter->UsePaletteAnimation()) {
        case Blitter::PALETTE_ANIMATION_VIDEO_BACKEND:
            this->UpdatePalette(_local_palette.first_dirty, _local_palette.count_dirty);
            break;

        case Blitter::PALETTE_ANIMATION_BLITTER:
            blitter->PaletteAnimate(_local_palette);
            break;

        case Blitter::PALETTE_ANIMATION_NONE:
            break;

        default:
            NOT_REACHED();
    }
}

/** Draw window */
void VideoDriver_CocoaQuartz::Paint()
{
    PerformanceMeasurer framerate(PFE_VIDEO);

    /* Check if we need to do anything */
    if (IsEmptyRect(this->dirty_rect) || [ this->window isMiniaturized ]) return;

    /* We only need to blit in indexed mode since in 32bpp mode the game draws directly to the image. */
    if (this->buffer_depth == 8) {
        BlitIndexedToView32(
            this->dirty_rect.left,
            this->dirty_rect.top,
            this->dirty_rect.right,
            this->dirty_rect.bottom
        );
    }

    NSRect dirtyrect;
    dirtyrect.origin.x = this->dirty_rect.left;
    dirtyrect.origin.y = this->window_height - this->dirty_rect.bottom;
    dirtyrect.size.width = this->dirty_rect.right - this->dirty_rect.left;
    dirtyrect.size.height = this->dirty_rect.bottom - this->dirty_rect.top;

    /* Notify OS X that we have new content to show. */
    [ this->cocoaview setNeedsDisplayInRect:[ this->cocoaview getVirtualRect:dirtyrect ] ];

    /* Tell the OS to get our contents to screen as soon as possible. */
    [ CATransaction flush ];

    this->dirty_rect = {};
}
