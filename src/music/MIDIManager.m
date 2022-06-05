//
//  MIDIManager.m
//  OpenTTD
//
//  Created by Christian Skaarup Enevoldsen on 18/08/2019.
//  Copyright © 2019 OpenTTD. All rights reserved.
//

#import "MIDIManager.h"
#import <AVFoundation/AVFoundation.h>

@interface AVAudioUnitMIDISynth : AVAudioUnitMIDIInstrument
- (void)loadMIDISynthSoundFont;
@end

@implementation AVAudioUnitMIDISynth
- (instancetype)init
{
	AudioComponentDescription description;
	description.componentType         = kAudioUnitType_MusicDevice;
	description.componentSubType      = kAudioUnitSubType_MIDISynth;
	description.componentManufacturer = kAudioUnitManufacturer_Apple;
	description.componentFlags        = 0;
	description.componentFlagsMask    = 0;
	
	self = [super initWithAudioComponentDescription:description];
	if (self) {
		
	}
	return self;
}

- (void)loadMIDISynthSoundFont {
//	NSString *path = [[NSBundle mainBundle] pathForResource:@"OPL-3_FM_128M" ofType:@"sf2"];
	NSString *path = [[NSBundle mainBundle] pathForResource:@"gs_instruments" ofType:@"dls"];
//	NSString *path = [[NSBundle mainBundle] pathForResource:@"weedsgm3" ofType:@"sf2"];
	const char *os_file = [path UTF8String];
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8*)os_file, strlen(os_file), false);
	if (path != nil) {
		
		OSStatus result = AudioUnitSetProperty(self.audioUnit, kMusicDeviceProperty_SoundBankURL, kAudioUnitScope_Global, 0, &url, sizeof(url));
		
		if (result != noErr) {
			NSLog(@"error (%d)", result);
		}
	} else {
		NSLog(@"Could not load sound font");
	}
	NSLog(@"loaded sound font");
}

@end


@interface MIDIManager ()
@property (strong) AVAudioEngine *engineMIDI;
@property (strong) AVAudioSequencer *sequencer;
@property (assign) NSTimeInterval maxTrackTime;
@end

@implementation MIDIManager

+ (id)sharedManager {
	static MIDIManager *sharedMyManager = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedMyManager = [[self alloc] init];
	});
	return sharedMyManager;
}

- (void)loadSongWith:(NSURL *)url {
	if (self.sequencer != nil || self.sequencer.isPlaying) {
		[self.sequencer stop];
		self.sequencer = nil;
	}
	
	self.maxTrackTime = 0;
	
	if (url != nil) {
		AVMusicSequenceLoadOptions options = AVMusicSequenceLoadSMF_PreserveTracks;
		self.sequencer = [[AVAudioSequencer alloc] initWithAudioEngine:self.engineMIDI];
		
		NSError* error = nil;
		[self.sequencer loadFromURL:url options:options error:&error];
		
		if (error == nil) {
			[self.sequencer prepareToPlay];
			[self.sequencer.tracks enumerateObjectsUsingBlock:^(AVMusicTrack * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
				if (self.maxTrackTime < obj.lengthInSeconds) {
					self.maxTrackTime = obj.lengthInSeconds;
				}
			}];
			self.maxTrackTime += 4;
		}
	}
}

- (void)playSong {
	NSError* error = nil;
	self.sequencer.currentPositionInBeats = 0;
	[self.sequencer startAndReturnError:&error];
	if (error) {
		NSLog(@"MIDI: Can't start (%@)", error);
	}
}

- (BOOL)playing {
	return self.sequencer == nil ? false : self.maxTrackTime > [self.sequencer currentPositionInSeconds];
}

- (void)stopSong {
	[self.sequencer stop];
}

- (void)setVolumeOfMIDI:(UInt8)volume {
	float f = ((float)volume)/255.0f;
	[[self.engineMIDI mainMixerNode] setOutputVolume:f];
}

- (void)loadManager {
	self.engineMIDI = [[AVAudioEngine alloc] init];
	
	AVAudioUnitMIDISynth *midiSynth = [[AVAudioUnitMIDISynth alloc] init]; // this is our guy
	[midiSynth loadMIDISynthSoundFont]; // overload to pass in a URL
	[self.engineMIDI attachNode:midiSynth];
	[self.engineMIDI connect:midiSynth to:self.engineMIDI.mainMixerNode format:nil];
	
	[self startEngine];
}

- (void)startEngine {
	if (self.engineMIDI.isRunning) {
		return;
	}
	
	NSError* error = nil;
	[self.engineMIDI startAndReturnError:&error];
	
	if (error) {
		NSLog(@"MIDI: %@", error);
	}
}

@end
