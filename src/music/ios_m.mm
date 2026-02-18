/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_m.mm MIDI music player for iOS using AVAudioEngine. */

#ifdef OTTD_IOS

#include "../stdafx.h"
#include "../debug.h"
#include "ios_m.h"
#include "midifile.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include "../safeguards.h"

static FMusicDriver_iOS iFMusicDriver_iOS;

@interface OTTD_iOSMIDISynth : AVAudioUnitMIDIInstrument
@end

@implementation OTTD_iOSMIDISynth
- (instancetype)init
{
	AudioComponentDescription desc{};
	desc.componentType = kAudioUnitType_MusicDevice;
	desc.componentSubType = kAudioUnitSubType_MIDISynth;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;

	self = [super initWithAudioComponentDescription:desc];
	return self;
}
@end

static AVAudioEngine *_engine = nil;
static OTTD_iOSMIDISynth *_midi_synth = nil;
static AVAudioSequencer *_sequencer = nil;
static NSTimeInterval _seq_length = 0.0;
static bool _playing = false;
static uint8_t _volume = 127;
static bool _custom_soundbank = false;

static NSURL *FindBundledSoundbankURL()
{
	NSBundle *bundle = [NSBundle mainBundle];
	NSString *path = [bundle pathForResource:@"gs_instruments" ofType:@"dls" inDirectory:@"baseset"];
	if (path == nil) path = [bundle pathForResource:@"gs_instruments" ofType:@"dls"];
	if (path == nil) return nil;

	return [NSURL fileURLWithPath:path];
}

static bool LoadSoundbank()
{
	if (_midi_synth == nil) return false;

	NSURL *url = FindBundledSoundbankURL();
	if (url == nil) {
		Debug(driver, 1, "ios_m: Custom soundbank baseset/gs_instruments.dls not found, falling back to Apple GM");
		return false;
	}

	std::string os_path = OTTD2FS([[url path] UTF8String]);
	CFURLRef cf_url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)os_path.c_str(), os_path.size(), false);
	if (cf_url == nullptr) {
		Debug(driver, 0, "ios_m: Failed to convert soundbank path '{}'", [[url path] UTF8String]);
		return false;
	}

	OSStatus status = AudioUnitSetProperty(_midi_synth.audioUnit, kMusicDeviceProperty_SoundBankURL, kAudioUnitScope_Global, 0, &cf_url, sizeof(cf_url));
	CFRelease(cf_url);
	if (status != noErr) {
		Debug(driver, 0, "ios_m: Failed to load custom soundbank '{}', status {}. Falling back to Apple GM.", [[url path] UTF8String], (int)status);
		return false;
	}

	Debug(driver, 1, "ios_m: Loaded custom soundbank '{}'", [[url path] UTF8String]);
	return true;
}

static void SetTrackOutputAndLength()
{
	if (_sequencer == nil || _midi_synth == nil) return;

	_seq_length = 0.0;
	for (AVMusicTrack *track in _sequencer.tracks) {
		track.destinationAudioUnit = _midi_synth;
		if (_seq_length < track.lengthInSeconds) _seq_length = track.lengthInSeconds;
	}

	/* Small tail for release/reverb. */
	_seq_length += 4.0;
}

static void DoSetVolume()
{
	if (_engine == nil) return;

	float vol = _volume / 127.0f;
	_engine.mainMixerNode.outputVolume = vol;
}

std::optional<std::string_view> MusicDriver_iOS::Start(const StringList &)
{
	this->Stop();

	_engine = [[AVAudioEngine alloc] init];
	if (_engine == nil) return "failed to create AVAudioEngine";

	_midi_synth = [[OTTD_iOSMIDISynth alloc] init];
	if (_midi_synth == nil) {
		[_engine release];
		_engine = nil;
		return "failed to create iOS MIDI synth";
	}

	[_engine attachNode:_midi_synth];
	[_engine connect:_midi_synth to:_engine.mainMixerNode format:nil];

	_custom_soundbank = LoadSoundbank();
	if (!_custom_soundbank) {
		Debug(driver, 1, "ios_m: Using Apple default MIDI instruments");
	}

	NSError *error = nil;
	if (![_engine startAndReturnError:&error]) {
		Debug(driver, 0, "ios_m: Failed to start AVAudioEngine: {}", error != nil ? [[error localizedDescription] UTF8String] : "unknown error");
		this->Stop();
		return "failed to start AVAudioEngine";
	}

	_playing = false;
	_seq_length = 0.0;
	DoSetVolume();

	return std::nullopt;
}

void MusicDriver_iOS::Stop()
{
	this->StopSong();

	if (_engine != nil && _engine.isRunning) [_engine stop];
	if (_engine != nil && _midi_synth != nil) [_engine detachNode:_midi_synth];

	if (_midi_synth != nil) {
		[_midi_synth release];
		_midi_synth = nil;
	}

	if (_engine != nil) {
		[_engine release];
		_engine = nil;
	}

	_custom_soundbank = false;
}

void MusicDriver_iOS::PlaySong(const MusicSongInfo &song)
{
	std::string filename = MidiFile::GetSMFFile(song);
	Debug(driver, 2, "ios_m: trying to play '{}'", filename);

	this->StopSong();
	if (filename.empty() || _engine == nil) return;

	std::string os_file = OTTD2FS(filename);
	NSString *path = [[NSString alloc] initWithBytes:os_file.data() length:os_file.size() encoding:NSUTF8StringEncoding];
	if (path == nil) {
		Debug(driver, 0, "ios_m: Failed to convert filename for AVAudioSequencer");
		return;
	}

	NSURL *url = [NSURL fileURLWithPath:path];
	[path release];

	_sequencer = [[AVAudioSequencer alloc] initWithAudioEngine:_engine];
	if (_sequencer == nil) {
		Debug(driver, 0, "ios_m: Failed to create AVAudioSequencer");
		return;
	}

	NSError *error = nil;
	if (![_sequencer loadFromURL:url options:AVMusicSequenceLoadSMF_PreserveTracks error:&error]) {
		Debug(driver, 0, "ios_m: Failed to load MIDI file: {}", error != nil ? [[error localizedDescription] UTF8String] : "unknown error");
		[_sequencer release];
		_sequencer = nil;
		return;
	}

	SetTrackOutputAndLength();
	[_sequencer prepareToPlay];
	_sequencer.currentPositionInBeats = 0;

	error = nil;
	if (![_sequencer startAndReturnError:&error]) {
		Debug(driver, 0, "ios_m: Failed to start playback: {}", error != nil ? [[error localizedDescription] UTF8String] : "unknown error");
		[_sequencer release];
		_sequencer = nil;
		return;
	}

	_playing = true;
	Debug(driver, 3, "ios_m: playing '{}'{}", filename, _custom_soundbank ? " (custom soundbank)" : " (Apple GM fallback)");
}

void MusicDriver_iOS::StopSong()
{
	if (_sequencer != nil) {
		[_sequencer stop];
		[_sequencer release];
		_sequencer = nil;
	}
	_playing = false;
	_seq_length = 0.0;
}

bool MusicDriver_iOS::IsSongPlaying()
{
	if (!_playing || _sequencer == nil) return false;
	if (!_sequencer.isPlaying) return false;

	return _sequencer.currentPositionInSeconds < _seq_length;
}

void MusicDriver_iOS::SetVolume(uint8_t vol)
{
	_volume = vol;
	DoSetVolume();
}

#endif /* OTTD_IOS */
