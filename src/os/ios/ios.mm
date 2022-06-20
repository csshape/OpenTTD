//
//  ios.cpp
//  OpenTTD
//
//  Created by Jesús A. Álvarez on 02/03/2017.
//  Copyright © 2017 OpenTTD. All rights reserved.
//

#import <UIKit/UIKit.h>

#include "../../stdafx.h"
#include "../../textbuf_gui.h"
#include "../../openttd.h"
#include "../../crashlog.h"
#include "../../core/random_func.hpp"
#include "../../debug.h"
#include "../../string_func.h"
#include "../../fios.h"
#include "../../thread.h"

#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include <signal.h>
#include <sys/mount.h>
#include <pthread.h>

#import "AppDelegate.h"
#import "MIDIManager.h"

#include "../../safeguards.h"

const char * _globalDataDir;

extern "C" {
	extern char ***_NSGetArgv(void);
	extern int *_NSGetArgc(void);
}

bool FiosIsRoot(const char *path)
{
    return path[1] == '\0';
}

void FiosGetDrives(FileList &file_list)
{
    extern std::array<std::string, NUM_SEARCHPATHS> _searchpaths;
    
	// Add link to Documents
    FiosItem *fios = &file_list.emplace_back();
    fios->type = FIOS_TYPE_DIRECT;
    fios->mtime = 0;
    
    std::string name = _searchpaths[SP_PERSONAL_DIR];
    strecpy(fios->name, name.c_str(), lastof(fios->name));
    strecpy(fios->title, "~/Documents", lastof(fios->title));

    return;
}

bool FiosGetDiskFreeSpace(const char *path, uint64 *tot)
{
    uint64 free = 0;
    struct statfs s;
    
    if (statfs(path, &s) != 0) return false;
    free = (uint64)s.f_bsize * s.f_bavail;
    if (tot != NULL) *tot = free;
    return true;
}

bool FiosIsValidFile(const char *path, const struct dirent *ent, struct stat *sb)
{
    char filename[MAX_PATH];
    int res;
    assert(path[strlen(path) - 1] == PATHSEPCHAR);
    if (strlen(path) > 2) assert(path[strlen(path) - 2] != PATHSEPCHAR);
    res = seprintf(filename, lastof(filename), "%s%s", path, ent->d_name);
    
    /* Could we fully concatenate the path and filename? */
    if (res >= (int)lengthof(filename) || res < 0) return false;
    
    return stat(filename, sb) == 0;
}

bool FiosIsHiddenFile(const struct dirent *ent)
{
    return ent->d_name[0] == '.';
}

const char *FS2OTTD(const char *name) {return name;}
const char *OTTD2FS(const char *name) {return name;}

void ShowInfo(const char *str)
{
    fprintf(stderr, "%s\n", str);
}

const char *OSErrorMessage = nullptr;

void ShowOSErrorBox(const char *buf, bool system)
{
	if ([UIApplication sharedApplication] == nil) {
		OSErrorMessage = buf;
		UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, @"AppDelegate");
	} else {
		[[UIApplication sharedApplication].delegate performSelector:@selector(showErrorMessage:) withObject:@(buf)];
	}
}

/**
 * Determine and return the current user's locale.
 */
const char *GetCurrentLocale(const char *)
{
    static char retbuf[32] = { '\0' };
    NSUserDefaults *defs = [ NSUserDefaults standardUserDefaults ];
    NSArray *languages = [ defs objectForKey:@"AppleLanguages" ];
    NSString *preferredLang = [ languages objectAtIndex:0 ];
    [ preferredLang getCString:retbuf maxLength:32 encoding:NSASCIIStringEncoding ];
    return retbuf;
}

/** Set the application's bundle directory.
 *
 * Set the relevant search paths for iOS (bundle and documents)
 */
void CocoaSetApplicationBundleDir()
{
    extern std::array<std::string, NUM_SEARCHPATHS> _searchpaths;
    
	NSString *documentsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject.stringByStandardizingPath stringByAppendingString:@"/"];
	_searchpaths[SP_FIRST_DIR].clear();
	_searchpaths[SP_PERSONAL_DIR] = stredup(documentsDirectory.fileSystemRepresentation);
	_searchpaths[SP_BINARY_DIR].clear();
	_searchpaths[SP_INSTALLATION_DIR].clear();
	_searchpaths[SP_APPLICATION_BUNDLE_DIR] = stredup(_globalDataDir);
}

bool GetClipboardContents(char *buffer, const char *last)
{
    UIPasteboard *pasteboard = [ UIPasteboard generalPasteboard ];
    if (pasteboard.hasStrings)
    {
        strecpy(buffer, pasteboard.string.UTF8String, last);
        return true;
    } else
    {
        return false;
    }
}

bool QZ_CanDisplay8bpp()
{
    return false;
}

void OSOpenBrowser(const char *url)
{
    [[ UIApplication sharedApplication ] openURL: [ NSURL URLWithString:@(url)] options: @{} completionHandler: nil ];
}

int main(int argc, char * argv[])
{
    @autoreleasepool
    {
        _globalDataDir = [[ NSBundle mainBundle ].resourcePath stringByAppendingString:@"/"].fileSystemRepresentation;
		
		[MIDIManager.sharedManager loadManager];
		
        SetRandomSeed(time(NULL));
        
        signal(SIGPIPE, SIG_IGN);
		
		return openttd_main(1, argv);
    }
}

/**
 * Set the name of the current thread for the debugger.
 * @param name The new name of the current thread.
 */
void SetCurrentThreadName(const char *name)
{
	pthread_setname_np(name);
	
	NSThread *cur = [ NSThread currentThread ];
	if (cur != NULL && [ cur respondsToSelector:@selector(setName:) ]) {
		[ cur performSelector:@selector(setName:) withObject:[ NSString stringWithUTF8String:name ] ];
	}
}

/* static */ void CrashLog::InitThread()
{
}

void loadMIDISong(CFURLRef url) {
	NSURL *nsurl = (NSURL *)CFBridgingRelease(url);
	[MIDIManager.sharedManager loadSongWith:nsurl];
}

void playMIDI() {
	[MIDIManager.sharedManager playSong];
}

void stopMIDI() {
	[MIDIManager.sharedManager stopSong];
}

bool isPlayningMIDI() {
	return [MIDIManager.sharedManager playing];
}

void setMIDIVolume(UInt8 volume) {
	[MIDIManager.sharedManager setVolumeOfMIDI:volume];
}


void GetMacOSVersion(int *return_major, int *return_minor, int *return_bugfix) {
    *return_major = -1;
    *return_minor = -1;
    *return_bugfix = -1;

    if ([[ NSProcessInfo processInfo] respondsToSelector:@selector(operatingSystemVersion) ]) {
        IMP sel = [ [ NSProcessInfo processInfo] methodForSelector:@selector(operatingSystemVersion) ];
        NSOperatingSystemVersion ver = ((NSOperatingSystemVersion (*)(id, SEL))sel)([ NSProcessInfo processInfo], @selector(operatingSystemVersion));

        *return_major = (int)ver.majorVersion;
        *return_minor = (int)ver.minorVersion;
        *return_bugfix = (int)ver.patchVersion;
    }
}
