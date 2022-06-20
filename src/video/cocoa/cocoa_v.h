/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_v.h The Cocoa video driver. */

#ifndef VIDEO_COCOA_H
#define VIDEO_COCOA_H

#include "video_driver.hpp"
#include "geometry_type.hpp"

#if defined(IOS)
#import <UIKit/UIKit.h>
#include "ios_wnd.h"
#else
#import <Cocoa/Cocoa.h>
#include "cocoa_wnd.h"
#endif

extern bool _cocoa_video_started;

@class OTTD_CocoaWindowDelegate;
@class OTTD_CocoaWindow;
@class OTTD_CocoaView;

class VideoDriver_Cocoa : public VideoDriver {
private:
	Dimension orig_res;       ///< Saved window size for non-fullscreen mode.
	bool refresh_sys_sprites; ///< System sprites need refreshing.

public:
	bool setup; ///< Window is currently being created.

	OTTD_CocoaWindow *window;    ///< Pointer to window object
	OTTD_CocoaView *cocoaview;   ///< Pointer to view object
	CGColorSpaceRef color_space; ///< Window color space

	OTTD_CocoaWindowDelegate *delegate; //!< Window delegate object

public:
	VideoDriver_Cocoa();

	void Stop() override;
	void MainLoop() override;

	void MakeDirty(int left, int top, int width, int height) override;
	bool AfterBlitterChange() override;

	bool ChangeResolution(int w, int h) override;
	bool ToggleFullscreen(bool fullscreen) override;

	void ClearSystemSprites() override;
	void PopulateSystemSprites() override;

	void EditBoxLostFocus() override;

	std::vector<int> GetListOfMonitorRefreshRates() override;

	/* --- The following methods should be private, but can't be due to Obj-C limitations. --- */

	void MainLoopReal();

	virtual void AllocateBackingStore(bool force = false) = 0;

protected:
	Rect dirty_rect;    ///< Region of the screen that needs redrawing.
	bool buffer_locked; ///< Video buffer was locked by the main thread.

	Dimension GetScreenSize() const override;
	float GetDPIScale() override;
	void InputLoop() override;
	bool LockVideoBuffer() override;
	void UnlockVideoBuffer() override;
	bool PollEvent() override;

	void GameSizeChanged();

	const char *Initialize();

	void UpdateVideoModes();

	bool MakeWindow(int width, int height);

#if defined(IOS)
	virtual UIView* AllocateDrawView() = 0;
#else
    virtual NSView* AllocateDrawView() = 0;
#endif

	/** Get a pointer to the video buffer. */
	virtual void *GetVideoPointer() = 0;
	/** Hand video buffer back to the drawing backend. */
	virtual void ReleaseVideoPointer() {}

private:
	bool IsFullscreen();
    jmp_buf main_loop_jmp;
};

#endif /* VIDEO_COCOA_H */
