/* $Id$ */

/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_touch_v.h The Cocoa Touch video driver. */


#ifndef VIDEO_COCOA_TOUCH_H
#define VIDEO_COCOA_TOUCH_H

#include "video_driver.hpp"

class VideoDriver_CocoaTouch : public VideoDriver {
public:
	/* virtual */ const char *Start(const char * const *param);
	
	/** Stop the video driver */
	/* virtual */ void Stop();
	
	/** Mark dirty a screen region
	 * @param left x-coordinate of left border
	 * @param top  y-coordinate of top border
	 * @param width width or dirty rectangle
	 * @param height height of dirty rectangle
	 */
	/* virtual */ void MakeDirty(int left, int top, int width, int height);
	
	/** Programme main loop */
	/* virtual */ void MainLoop();
	void ExitMainLoop();
	
	/** Change window resolution
	 * @param w New window width
	 * @param h New window height
	 * @return Whether change was successful
	 */
	/* virtual */ bool ChangeResolution(int w, int h);
	
	/** Set a new window mode
	 * @param fullscreen Whether to set fullscreen mode or not
	 * @return Whether changing the screen mode was successful
	 */
	/* virtual */ bool ToggleFullscreen(bool fullscreen);
	
	/** Callback invoked after the blitter was changed.
	 * @return True if no error.
	 */
	/* virtual */ bool AfterBlitterChange();
	
	/**
	 * An edit box lost the input focus. Abort character compositing if necessary.
	 */
	/* virtual */ void EditBoxLostFocus();
	
	void Draw();
	void UpdatePalette(uint first_color, uint num_colors);

	/** Return driver name
	 * @return driver name
	 */
	/* virtual */ const char *GetName() const { return "cocoa_touch"; }
private:
	
	CGContextRef context;
	void *pixel_buffer;
	jmp_buf main_loop_jmp;
};

class FVideoDriver_CocoaTouch : public DriverFactoryBase {
public:
	FVideoDriver_CocoaTouch() : DriverFactoryBase(Driver::DT_VIDEO, 10, "cocoa_touch", "Cocoa Touch Video Driver") {}
	/* virtual */ Driver *CreateInstance() const { return new VideoDriver_CocoaTouch(); }
};

extern VideoDriver_CocoaTouch *_cocoa_touch_driver;

#endif /* VIDEO_COCOA_TOUCH_H */
