//
//  VideoDriver_CocoaQuartz.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 06/06/2022.
//

#ifndef VIDEO_COCOA_QUARTZ_H
#define VIDEO_COCOA_QUARTZ_H

#include "cocoa_v.h"

class VideoDriver_CocoaQuartz : public VideoDriver_Cocoa {
private:
    int buffer_depth;     ///< Colour depth of used frame buffer
    void *pixel_buffer;   ///< used for direct pixel access
    void *window_buffer;  ///< Colour translation from palette to screen

    int window_width;     ///< Current window width in pixel
    int window_height;    ///< Current window height in pixel
    int window_pitch;

    uint32 palette[256];  ///< Colour Palette

    void BlitIndexedToView32(int left, int top, int right, int bottom);
    void UpdatePalette(uint first_color, uint num_colors);

public:
    CGContextRef cgcontext;      ///< Context reference for Quartz subdriver

    VideoDriver_CocoaQuartz();

    const char *Start(const StringList &param) override;
    void Stop() override;

    /** Return driver name */
    const char *GetName() const override { return "cocoa"; }

    void AllocateBackingStore(bool force = false) override;

protected:
    void Paint() override;
    void CheckPaletteAnim() override;

    NSView* AllocateDrawView() override;

    void *GetVideoPointer() override { return this->buffer_depth == 8 ? this->pixel_buffer : this->window_buffer; }
};

class FVideoDriver_CocoaQuartz : public DriverFactoryBase {
public:
    FVideoDriver_CocoaQuartz() : DriverFactoryBase(Driver::DT_VIDEO, 8, "cocoa", "Cocoa Video Driver") {}
    Driver *CreateInstance() const override { return new VideoDriver_CocoaQuartz(); }
};

#endif /* VIDEO_COCOA_QUARTZ_H */
