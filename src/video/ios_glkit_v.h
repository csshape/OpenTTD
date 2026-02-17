/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_glkit_v.h iOS Metal video driver (SDL2-free). */

#ifndef VIDEO_IOS_GLKIT_V_H
#define VIDEO_IOS_GLKIT_V_H

#include "video_driver.hpp"
#include <atomic>

/** iOS video driver using UIKit + Metal (SDL2-free). */
class VideoDriver_iOS_Metal : public VideoDriver {
public:
	VideoDriver_iOS_Metal() : VideoDriver(false) {}

	std::optional<std::string_view> Start(const StringList &param) override;
	void Stop() override;

	void MainLoop() override;
	void MakeDirty(int left, int top, int width, int height) override;
	void CheckPaletteAnim() override;
	bool ChangeResolution(int w, int h) override;
	bool ToggleFullscreen(bool fullscreen) override;
	bool AfterBlitterChange() override;
	void SetScreensaverInhibited(bool inhibited) override;
	bool UseSystemCursor() override { return true; }

	std::vector<int> GetListOfMonitorRefreshRates() override;
	std::string_view GetInfoString() const override { return this->driver_info; }
	std::string_view GetName() const override { return "ios-metal"; }

	void OnDisplayFrame();
	void NotifySizeChanged();

private:
	std::atomic<bool> allow_tick{false};
	bool buffer_locked = false;
	Rect dirty_rect{};
	Palette local_palette{};
	std::string driver_info{"ios-metal"};

	void *ui_window = nullptr;
	void *root_controller = nullptr;
	void *metal_view = nullptr;
	void *metal_layer = nullptr;
	void *metal_device = nullptr;
	void *metal_queue = nullptr;
	void *metal_pipeline = nullptr;
	void *metal_texture = nullptr;
	void *display_link = nullptr;
	void *display_link_target = nullptr;

	uint8_t *pixel_buffer = nullptr;
	uint32_t *rgba_buffer = nullptr;
	int vid_w = 0;
	int vid_h = 0;

	Dimension GetScreenSize() const override;
	bool LockVideoBuffer() override;
	void UnlockVideoBuffer() override;
	bool PollEvent() override { return false; }

	void Paint() override;
	void *GetVideoPointer();
	void ReleaseVideoPointer();

	bool SetupContextAndView();
	bool StartDisplayLink();
	void StopDisplayLink();
	void TeardownContextAndView();
	bool AllocateBackingStore(int w, int h, bool force = false);
	void DestroyMetalResources();
	bool InitMetalPipeline();
};

/** Primary factory for iOS Metal video driver. */
class FVideoDriver_iOS_Metal : public DriverFactoryBase {
public:
	FVideoDriver_iOS_Metal() : DriverFactoryBase(Driver::Type::Video, 9, "ios-metal", "iOS Metal Video Driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS_Metal>(); }
};

/** Compatibility factory for older iOS config using "ios-glkit". */
class FVideoDriver_iOS_MetalCompatGLKit : public DriverFactoryBase {
public:
	FVideoDriver_iOS_MetalCompatGLKit() : DriverFactoryBase(Driver::Type::Video, 8, "ios-glkit", "iOS Metal Video Driver (compat)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS_Metal>(); }
};

/** Compatibility factory for old iOS configs using "sdl-opengles". */
class FVideoDriver_iOS_MetalCompatGLES : public DriverFactoryBase {
public:
	FVideoDriver_iOS_MetalCompatGLES() : DriverFactoryBase(Driver::Type::Video, 7, "sdl-opengles", "iOS Metal Video Driver (compat)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS_Metal>(); }
};

/** Compatibility factory for old iOS configs using "sdl". */
class FVideoDriver_iOS_MetalCompatSDL : public DriverFactoryBase {
public:
	FVideoDriver_iOS_MetalCompatSDL() : DriverFactoryBase(Driver::Type::Video, 6, "sdl", "iOS Metal Video Driver (legacy compat)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_iOS_Metal>(); }
};

#endif /* VIDEO_IOS_GLKIT_V_H */
