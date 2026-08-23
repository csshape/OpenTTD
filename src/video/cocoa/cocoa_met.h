/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file cocoa_met.h The Cocoa Metal video driver. */

#ifndef VIDEO_COCOA_MET_H
#define VIDEO_COCOA_MET_H

#include "cocoa_v.h"

class VideoDriver_CocoaMetal : public VideoDriver_Cocoa {
	/* Metal objects are held as void * so this header stays includable from
	 * plain C++ translation units; the .mm file casts them back. */
	void *device;           ///< id<MTLDevice>
	void *queue;            ///< id<MTLCommandQueue>
	void *pipeline;         ///< id<MTLRenderPipelineState>, 32bpp BGRA path
	void *pipeline_indexed; ///< id<MTLRenderPipelineState>, 8bpp indexed path
	void *texture;          ///< id<MTLTexture> holding the game's pixels
	void *palette_texture;  ///< id<MTLTexture> 1D palette for the indexed path
	void *metal_layer;      ///< CAMetalLayer the drawable comes from

	std::unique_ptr<uint8_t[]> pixel_buffer; ///< Buffer the game blits into.
	int vid_w;             ///< Width of pixel_buffer and texture, in pixels.
	int vid_h;             ///< Height of pixel_buffer and texture, in pixels.
	int buffer_depth;      ///< Colour depth of pixel_buffer (8 or 32).

	std::string driver_info; ///< Information string about the selected driver.

	std::optional<std::string_view> AllocateMetalResources();
	void ReleaseMetalResources();
	bool ResizeBackingStore(int w, int h, bool force);

public:
	VideoDriver_CocoaMetal() : VideoDriver_Cocoa(true), device(nullptr), queue(nullptr),
		pipeline(nullptr), pipeline_indexed(nullptr), texture(nullptr), palette_texture(nullptr),
		metal_layer(nullptr), vid_w(0), vid_h(0), buffer_depth(0),
		driver_info(this->GetName()) {}

	std::optional<std::string_view> Start(const StringList &param) override;
	void Stop() override;

	bool HasEfficient8Bpp() const override { return true; }

	bool UseSystemCursor() override { return true; }

	std::string_view GetName() const override { return "cocoa-metal"; }

	std::string_view GetInfoString() const override { return this->driver_info; }

	void AllocateBackingStore(bool force = false) override;

protected:
	void Paint() override;

	void *GetVideoPointer() override;
	void ReleaseVideoPointer() override;

	NSView *AllocateDrawView() override;
};

class FVideoDriver_CocoaMetal : public DriverFactoryBase {
public:
	/* Priority 1 keeps this below cocoa (8) and cocoa-opengl (9) so autoprobe
	 * never picks it: the renderer still presents a black screen, so it must be
	 * requested explicitly with -v cocoa-metal while that is being fixed. */
	FVideoDriver_CocoaMetal() : DriverFactoryBase(Driver::Type::Video, 1, "cocoa-metal", "Cocoa Metal Video Driver") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<VideoDriver_CocoaMetal>(); }

protected:
	bool UsesHardwareAcceleration() const override { return true; }
};

#endif /* VIDEO_COCOA_MET_H */
