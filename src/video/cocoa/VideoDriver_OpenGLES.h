//
//  VideoDriver_OpenGLES.h
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 06/06/2022.
//

#ifndef VIDEO_OPEN_GLES_H
#define VIDEO_OPEN_GLES_H

#import <UIKit/UIKit.h>

#include "cocoa_v.h"

class VideoDriver_OpenGLES : public VideoDriver_Cocoa {
private:
    int buffer_depth;     ///< Colour depth of used frame buffer
    void *pixel_buffer;   ///< used for direct pixel access
    
    int window_width;     ///< Current window width in pixel
    int window_height;    ///< Current window height in pixel
    int window_pitch;

    uint32 palette[256];  ///< Colour Palette

    void BlitIndexedToView32(int left, int top, int right, int bottom);
    void UpdatePalette(uint first_color, uint num_colors);
    void OpenGLStart();
public:
    VideoDriver_OpenGLES();

    CGContextRef context;
    
    BOOL isLandscape;
    
    const char *Start(const StringList &param) override;
    void Stop() override;

    /** Return driver name */
    const char *GetName() const override { return "opengles"; }

    void AllocateBackingStore(bool force = false) override;

    void Draw();
    void OpenGLTick();
    void OpenGLStartGame();
    void OpenGLStopGame();
protected:
    void Paint() override;
    void CheckPaletteAnim() override;

    UIView* AllocateDrawView() override;

    void *GetVideoPointer() override { return this->pixel_buffer; }
};

class FVideoDriver_OpenGLES : public DriverFactoryBase {
public:
    FVideoDriver_OpenGLES() : DriverFactoryBase(Driver::DT_VIDEO, 8, "opengles", "OpenGLES Video Driver") {}
    Driver *CreateInstance() const override { return new VideoDriver_OpenGLES(); }
};

extern VideoDriver_OpenGLES *_cocoa_touch_driver;

@interface OTTD_OpenGLESView : UIView {
    VideoDriver_OpenGLES *driver;
}
- (instancetype)initWithFrame:(CGRect)frameRect andDriver:(VideoDriver_OpenGLES *)drv;
@end

#endif /* VIDEO_OPEN_GLES_H */
