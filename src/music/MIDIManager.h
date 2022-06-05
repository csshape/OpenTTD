//
//  MIDIManager.h
//  OpenTTD
//
//  Created by Christian Skaarup Enevoldsen on 18/08/2019.
//  Copyright © 2019 OpenTTD. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MIDIManager : NSObject

+ (id)sharedManager;

- (void)loadManager;
- (void)loadSongWith:(NSURL *)url;
- (void)playSong;
- (void)stopSong;
- (BOOL)playing;
- (void)setVolumeOfMIDI:(UInt8)volume;

@end

NS_ASSUME_NONNULL_END
