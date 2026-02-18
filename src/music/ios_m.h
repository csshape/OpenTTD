/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_m.h Base of music playback via AVAudioEngine on iOS. */

#ifndef MUSIC_IOS_H
#define MUSIC_IOS_H

#include "music_driver.hpp"

class MusicDriver_iOS : public MusicDriver {
public:
	std::optional<std::string_view> Start(const StringList &param) override;

	void Stop() override;

	void PlaySong(const MusicSongInfo &song) override;

	void StopSong() override;

	bool IsSongPlaying() override;

	void SetVolume(uint8_t vol) override;
	std::string_view GetName() const override { return "ios"; }
};

class FMusicDriver_iOS : public DriverFactoryBase {
public:
	FMusicDriver_iOS() : DriverFactoryBase(Driver::Type::Music, 10, "ios", "iOS MIDI Driver (custom soundbank: baseset/gs_instruments.dls)") {}
	std::unique_ptr<Driver> CreateInstance() const override { return std::make_unique<MusicDriver_iOS>(); }
};

#endif /* MUSIC_IOS_H */
