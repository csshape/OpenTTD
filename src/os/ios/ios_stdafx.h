/* $Id$ */

/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file ios_stdafx.h iOS is different on some places. */

#ifndef IOS_STDAFX_H
#define IOS_STDAFX_H

#include <TargetConditionals.h>
#include <AvailabilityMacros.h>

#define __STDC_LIMIT_MACROS
#include <stdint.h>

/* Some gcc versions include assert.h via this header. As this would interfere
 * with our own assert redefinition, include this header first. */
#if !defined(__clang__) && defined(__GNUC__) && (__GNUC__ > 3 || (__GNUC__ == 3 && __GNUC_MINOR__ >= 3))
#	include <debug/debug.h>
#endif

/* Check for mismatching 'architectures' */
#if defined(__LP64__)
#define _SQ64
#endif

extern const char * _globalDataDir;
#define GLOBAL_DATA_DIR _globalDataDir

#include <CoreFoundation/CoreFoundation.h>

/* Name conflict */
#if 0
#define Rect        OTTDRect
#define Point       OTTDPoint
#define WindowClass OTTDWindowClass
#define ScriptOrder OTTDScriptOrder
#define Palette     OTTDPalette
#define GlyphID     OTTDGlyphID

#include <ApplicationServices/ApplicationServices.h>

#undef Rect
#undef Point
#undef WindowClass
#undef ScriptOrder
#undef Palette
#undef GlyphID

/* remove the variables that CoreServices defines, but we define ourselves too */
#undef bool
#undef false
#undef true

#endif

/* Name conflict */
#define GetTime OTTD_GetTime

#define SL_ERROR OSX_SL_ERROR

void loadMIDISong(CFURLRef url);
void playMIDI();
bool isPlayningMIDI();
void stopMIDI();
void setMIDIVolume(UInt8 volume);

#endif /* IOS_STDAFX_H */
