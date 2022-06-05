/* $Id$ */

/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/**
 * @file cocoa_touch_m.cpp
 * @brief MIDI music player for iOS using CoreAudio.
 */


#ifdef WITH_COCOA_TOUCH

#include "stdafx.h"
#include "cocoa_touch_m.h"
#include "midifile.hpp"
#include "debug.h"


#include "safeguards.h"

static FMusicDriver_iOS iFMusicDriver_iOS;


/**
 * Initializes the MIDI player
 */
const char *MusicDriver_iOS::Start(const StringList &parm)
{
	return NULL;
}


/**
 * Checks wether the player is active.
 */
bool MusicDriver_iOS::IsSongPlaying()
{
	return isPlayningMIDI();
}


/**
 * Stops the MIDI player.
 */
void MusicDriver_iOS::Stop()
{
	stopMIDI();
}


/**
 * Starts playing a new song.
 *
 * @param song Description of music to load and play
 */
void MusicDriver_iOS::PlaySong(const MusicSongInfo &song)
{
	std::string filename = MidiFile::GetSMFFile(song);
    //TODO: For CSE
//	DEBUG(driver, 2, "cocoa_touch_m: trying to play '%s'", filename.c_str());

	this->StopSong();
	
	if (filename.empty()) return;

    std::string os_file = OTTD2FS(filename);
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8*)os_file.c_str(), os_file.length(), false);

	loadMIDISong(url);
	
	playMIDI();
    //TODO: For CSE
//	DEBUG(driver, 3, "cocoa_touch_m: playing '%s'", filename.c_str());
}


/**
 * Stops playing the current song, if the player is active.
 */
void MusicDriver_iOS::StopSong()
{
	stopMIDI();
}


/**
 * Changes the playing volume of the MIDI player.
 *
 * @param vol The desired volume, range of the value is @c 0-127
 */
void MusicDriver_iOS::SetVolume(byte vol)
{
	setMIDIVolume(vol);
}

#endif /* WITH_COCOA_TOUCH */
