/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0>.
 */

/** @file ios_s.cpp Sound driver for iOS. */

#ifdef OTTD_IOS

#include "../stdafx.h"
#include "../debug.h"
#include "../driver.h"
#include "../mixer.h"
#include "ios_s.h"

#define Rect  OTTDRect
#define Point OTTDPoint
#include <AudioUnit/AudioUnit.h>
#undef Rect
#undef Point

#include "../safeguards.h"

static FSoundDriver_iOS iFSoundDriver_iOS;
static AudioUnit _output_audio_unit = nullptr;

/* The CoreAudio callback. */
static OSStatus audioCallback(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *ioData)
{
	MxMixSamples(ioData->mBuffers[0].mData, ioData->mBuffers[0].mDataByteSize / 4);

	return noErr;
}

std::optional<std::string_view> SoundDriver_iOS::Start(const StringList &parm)
{
	AURenderCallbackStruct callback {};
	AudioStreamBasicDescription requested_desc {};

	/* Setup an AudioStreamBasicDescription with the requested format. */
	requested_desc.mFormatID = kAudioFormatLinearPCM;
	requested_desc.mFormatFlags = kLinearPCMFormatFlagIsPacked;
	requested_desc.mChannelsPerFrame = 2;
	requested_desc.mSampleRate = GetDriverParamInt(parm, "hz", 44100);
	requested_desc.mBitsPerChannel = 16;
	requested_desc.mFormatFlags |= kLinearPCMFormatFlagIsSignedInteger;
	requested_desc.mFramesPerPacket = 1;
	requested_desc.mBytesPerFrame = requested_desc.mBitsPerChannel * requested_desc.mChannelsPerFrame / 8;
	requested_desc.mBytesPerPacket = requested_desc.mBytesPerFrame * requested_desc.mFramesPerPacket;

	MxInitialize((uint)requested_desc.mSampleRate);

	/* Locate the default iOS output audio unit. */
	AudioComponentDescription desc {};
	desc.componentType = kAudioUnitType_Output;
	desc.componentSubType = kAudioUnitSubType_RemoteIO;
	desc.componentManufacturer = kAudioUnitManufacturer_Apple;

	AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
	if (comp == nullptr) return "ios_s: Failed to start CoreAudio: AudioComponentFindNext returned nullptr";

	/* Open and initialize the default output audio unit. */
	if (AudioComponentInstanceNew(comp, &_output_audio_unit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioComponentInstanceNew";
	}
	if (AudioUnitInitialize(_output_audio_unit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitInitialize";
	}

	/* Set the input format of the audio unit. */
	if (AudioUnitSetProperty(_output_audio_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &requested_desc, sizeof(requested_desc)) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitSetProperty (kAudioUnitProperty_StreamFormat)";
	}

	/* Set the audio callback. */
	callback.inputProc = audioCallback;
	callback.inputProcRefCon = nullptr;
	if (AudioUnitSetProperty(_output_audio_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioUnitSetProperty (kAudioUnitProperty_SetRenderCallback)";
	}

	/* Finally, start processing of the audio unit. */
	if (AudioOutputUnitStart(_output_audio_unit) != noErr) {
		return "ios_s: Failed to start CoreAudio: AudioOutputUnitStart";
	}

	return std::nullopt;
}

void SoundDriver_iOS::Stop()
{
	if (_output_audio_unit == nullptr) return;

	AURenderCallbackStruct callback {};

	/* Stop processing the audio unit. */
	if (AudioOutputUnitStop(_output_audio_unit) != noErr) {
		Debug(driver, 0, "ios_s: Core_CloseAudio: AudioOutputUnitStop failed");
	}

	/* Remove the input callback. */
	if (AudioUnitSetProperty(_output_audio_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) {
		Debug(driver, 0, "ios_s: Core_CloseAudio: AudioUnitSetProperty (kAudioUnitProperty_SetRenderCallback) failed");
	}

	if (AudioUnitUninitialize(_output_audio_unit) != noErr) {
		Debug(driver, 0, "ios_s: Core_CloseAudio: AudioUnitUninitialize failed");
	}

	if (AudioComponentInstanceDispose(_output_audio_unit) != noErr) {
		Debug(driver, 0, "ios_s: Core_CloseAudio: AudioComponentInstanceDispose failed");
	}

	_output_audio_unit = nullptr;
}

#endif /* OTTD_IOS */
