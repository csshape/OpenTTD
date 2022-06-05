/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_touch_m.h Base of music playback via CoreAudio. */

#ifndef MUSIC_IOS_H
#define MUSIC_IOS_H

#include "music_driver.hpp"

class MusicDriver_iOS : public MusicDriver {
public:
    const char *Start(const StringList &param) override;

    void Stop() override;

    void PlaySong(const MusicSongInfo &song) override;

    void StopSong() override;

    bool IsSongPlaying() override;

    void SetVolume(byte vol) override;
    const char *GetName() const override { return "iOS"; }
};

class FMusicDriver_iOS : public DriverFactoryBase {
public:
    FMusicDriver_iOS() : DriverFactoryBase(Driver::DT_MUSIC, 10, "iOS", "iOS MIDI Driver") {}
    Driver *CreateInstance() const override { return new MusicDriver_iOS(); }
};

#endif /* MUSIC_IOS_H */
