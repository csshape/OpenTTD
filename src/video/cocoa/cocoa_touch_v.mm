/* $Id$ */

/*
 * This file is part of OpenTTD.
 * OpenTTD is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 2.
 * OpenTTD is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with OpenTTD. If not, see <http://www.gnu.org/licenses/>.
 */

/** @file cocoa_touch_v.mm Code related to the cocoa touch video driver(s). */

#import <UIKit/UIKit.h>
#ifdef WITH_METAL
#import <Metal/Metal.h>
#endif
#ifdef WITH_OPENGL
#import <OpenGLES/gltypes.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#endif
#include "stdafx.h"
#import "cocoa_touch_v.h"
#import "../../os/ios/OpenTTD/AppDelegate.h"
#include "openttd.h"
#include "debug.h"
#include "factory.hpp"
#include "gfx_func.h"
#include "fontcache.h"

void HideOnScreenKeyboard();
static FVideoDriver_CocoaTouch iFVideoDriver_CocoaTouch;
VideoDriver_CocoaTouch *_cocoa_touch_driver = NULL;

#if defined(WITH_METAL) && TARGET_OS_SIMULATOR
// Metal is not supported in simulator
#undef WITH_METAL
#endif

#ifdef WITH_METAL
static id<MTLCommandQueue> commandQueue = nil;
static id<MTLRenderPipelineState> pipelineState = nil;
static id<MTLBuffer> vertexBuffer = nil;
static id<MTLBuffer> screenBuffer = nil;
static id<MTLTexture> screenTexture = nil;
#endif

#ifdef WITH_OPENGL
static EAGLContext *glContext = nil;
static GLuint positionSlot = 0;
static GLuint texcoordSlot = 0;
static GLuint textureUniform = 0;
static GLuint glVertexBuffer = 0;
static GLuint glScreenTexture = 0;
static GLuint framebuffer;
static GLuint renderbuffer;
static CGRect lastBounds;

typedef struct gl_vertex {
	float position[3];
	float texcoord[2];
} gl_vertex;
#endif

extern "C" {
	CALayer *_cocoa_touch_layer = NULL;
	extern char ***_NSGetArgv(void);
	extern int *_NSGetArgc(void);
	extern jmp_buf _out_of_loop;
}

const char *VideoDriver_CocoaTouch::Start(const char * const *parm)
{
	// TODO: detect start in landscape
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults registerDefaults:@{@"Video": @"metal",
								 @"NativeResolution": @NO}];
	UIScreen *mainScreen = [UIScreen mainScreen];
	CGFloat scale = [defaults boolForKey:@"NativeResolution"] ? mainScreen.nativeScale : 1.0;
	_resolutions[0].width = mainScreen.bounds.size.width * scale;
	_resolutions[0].height = mainScreen.bounds.size.height * scale;
	_num_resolutions = 1;
	_fullscreen = true;
	_cocoa_touch_driver = this;
	
	NSString *selectedDriver = [defaults stringForKey:@"Video"];
	
#ifdef WITH_METAL
	if (_cocoa_touch_layer == NULL && [selectedDriver isEqualToString:@"metal"]) {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		CAMetalLayer *metalLayer = nil;
		if (device && [device supportsFeatureSet:MTLFeatureSet_iOS_GPUFamily1_v1]) {
			metalLayer = [CAMetalLayer layer];
			metalLayer.device = device;
			metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
			metalLayer.framebufferOnly = YES;
		} else {
			goto metal_fail;
		}
		
		NSError *error = NULL;
		NSString *libraryPath = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"metallib"];
		id<MTLLibrary> library = [metalLayer.device newLibraryWithFile:libraryPath error:&error];
		
		MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
		pipelineDescriptor.vertexFunction = [library newFunctionWithName:@"basic_vertex"];
		pipelineDescriptor.fragmentFunction = [library newFunctionWithName:@"basic_fragment"];
		pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	
		float vertices[] = {
			-1.0, -1.0,
			-1.0, 1.0,
			1.0, -1.0,
			1.0, 1.0
		};
		 
		pipelineState = [metalLayer.device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
		commandQueue = [metalLayer.device newCommandQueue];
		vertexBuffer = [metalLayer.device newBufferWithBytes:&vertices length:sizeof(vertices) options:MTLResourceOptionCPUCacheModeDefault];
		if (error) {
			NSLog(@"Error initializing pipeline state: %@", error.localizedDescription);
			goto metal_fail;
		}
		_cocoa_touch_layer = metalLayer;
	}
metal_fail:
	if (_cocoa_touch_layer == NULL && [selectedDriver isEqualToString:@"metal"]) {
		selectedDriver = @"opengl";
		commandQueue = nil;
		pipelineState = nil;
		vertexBuffer = nil;
	}
#endif
	
#if WITH_OPENGL
	if (_cocoa_touch_layer == NULL && ![selectedDriver isEqualToString:@"quartz"]) {
		glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
		CAEAGLLayer *eaglLayer = NULL;
		if (glContext != nil) {
			eaglLayer = [CAEAGLLayer layer];
			eaglLayer.opaque = YES;
			eaglLayer.contentsScale = [UIScreen mainScreen].nativeScale;
		} else {
			NSLog(@"Error initializing context");
			goto opengl_fail;
		}
		
		__block NSError *error = nil;
		
		if (![EAGLContext setCurrentContext:glContext]) {
			NSLog(@"Error setting current context");
			goto opengl_fail;
		}
		
		GLuint (^compile)(NSString *, GLenum) = ^(NSString *name, GLenum type) {
			NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"glsl"];
			NSString *string = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
			if (!string) {
				NSLog(@"Error loading shader \"%@\": %@", name, error.localizedDescription);
				return (GLuint)0;
			}
			
			GLuint handle = glCreateShader(type);
			
			const GLchar *program = [string UTF8String];
			const GLint length = (GLint)string.length;
			glShaderSource(handle, 1, &program, &length);
			glCompileShader(handle);
			
			GLint success;
			glGetShaderiv(handle, GL_COMPILE_STATUS, &success);
			if (success == GL_FALSE) {
				GLchar messages[256];
				glGetShaderInfoLog(handle, sizeof(messages), 0, messages);
				NSLog(@"%@", @(messages));
				return (GLuint)0;
			}
			
			return handle;
		};
		
		glGenRenderbuffers(1, &renderbuffer);
		glGenFramebuffers(1, &framebuffer);
		
		GLuint vertexShader = compile(@"Vertex", GL_VERTEX_SHADER);
		GLuint fragmentShader = compile(@"Fragment", GL_FRAGMENT_SHADER);
		if (vertexShader == 0 || fragmentShader == 0)
			goto opengl_fail;
		
		GLuint program = glCreateProgram();
		glAttachShader(program, vertexShader);
		glAttachShader(program, fragmentShader);
		glLinkProgram(program);
		
		GLint success;
		glGetProgramiv(program, GL_LINK_STATUS, &success);
		if (success == GL_FALSE) {
			GLchar messages[256];
			glGetProgramInfoLog(program, sizeof(messages), 0, messages);
			NSLog(@"%@", @(messages));
			goto opengl_fail;
		}
		
		glUseProgram(program);
		
		positionSlot = glGetAttribLocation(program, "position");
		texcoordSlot = glGetAttribLocation(program, "texcoord_in");
		glEnableVertexAttribArray(positionSlot);
		glEnableVertexAttribArray(texcoordSlot);
		
		textureUniform = glGetUniformLocation(program, "texture");
		
		const gl_vertex vertices[] = {
			{{-1, -1, 0}, {0, 1}},
			{{-1, 1, 0}, {0, 0}},
			{{1, -1, 0}, {1, 1}},
			{{1, 1, 0}, {1, 0}}
		};
		glGenBuffers(1, &glVertexBuffer);
		glBindBuffer(GL_ARRAY_BUFFER, glVertexBuffer);
		glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		
		glGenTextures(1, &glScreenTexture);
		glBindTexture(GL_TEXTURE_2D, glScreenTexture);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		glBindTexture(GL_TEXTURE_2D, 0);
		
		[EAGLContext setCurrentContext:nil];
		selectedDriver = @"opengl";
		_cocoa_touch_layer = eaglLayer;
	}
opengl_fail:
	if (_cocoa_touch_layer == NULL && [selectedDriver isEqualToString:@"opengl"]) {
		if (glContext) {
			[EAGLContext setCurrentContext:glContext];
			glDeleteTextures(1, &glScreenTexture);
			glDeleteBuffers(1, &glVertexBuffer);
			[EAGLContext setCurrentContext:nil];
			glContext = nil;
		}
	}
#endif
	
	if (_cocoa_touch_layer == NULL) {
		selectedDriver = @"quartz";
		_cocoa_touch_layer = [CALayer layer];
	}

	// update defaults to reflect used driver
	NSLog(@"Updating video driver setting: %@", selectedDriver);
	[defaults setValue:selectedDriver forKey:@"Video"];
	
	this->ChangeResolution(_resolutions[0].width, _resolutions[0].height);

	return NULL;
}

void VideoDriver_CocoaTouch::Stop()
{
	_cocoa_touch_driver = NULL;
	
#ifdef WITH_METAL
	if (commandQueue) {
		commandQueue = nil;
		pipelineState = nil;
		vertexBuffer = nil;
		screenBuffer = nil;
		screenTexture = nil;
	}
#endif
	
#ifdef WITH_OPENGL
	if (glContext) {
		[EAGLContext setCurrentContext:glContext];
		glDeleteTextures(1, &glScreenTexture);
		glDeleteBuffers(1, &glVertexBuffer);
		positionSlot = 0;
		texcoordSlot = 0;
		textureUniform = 0;
		[EAGLContext setCurrentContext:nil];
		glContext = nil;
	}
#endif
	
	if (this->context) {
		CGContextRelease(this->context);
	}
	if (this->pixel_buffer) {
		free(this->pixel_buffer);
		this->pixel_buffer = NULL;
	}
	_cocoa_touch_layer = nil;
}

void VideoDriver_CocoaTouch::ExitMainLoop()
{
	CFRunLoopStop([[NSRunLoop mainRunLoop] getCFRunLoop]);
	longjmp(main_loop_jmp, 1);
}

void VideoDriver_CocoaTouch::MainLoop()
{
	if (setjmp(main_loop_jmp) == 0) {
		UIApplication *app = [UIApplication sharedApplication];
		if (app == nil) {
			UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), nil, @"AppDelegate");
		} else {
			// this only happens after bootstrap
			[app.delegate performSelector:@selector(startGameLoop)];
			[[NSRunLoop mainRunLoop] run];
		}
	}
}

void VideoDriver_CocoaTouch::MakeDirty(int left, int top, int width, int height)
{
	
}

bool VideoDriver_CocoaTouch::ChangeResolution(int w, int h)
{
	_screen.width = w;
	_screen.height = h;
	_screen.pitch = _screen.width;
#ifdef WITH_METAL
	BOOL usingMetal = [_cocoa_touch_layer isKindOfClass:[CAMetalLayer class]];
	if (usingMetal && _screen.pitch % 64) {
		_screen.pitch += (64 - (_screen.pitch % 64));
	}
#endif
	Blitter *blitter = BlitterFactory::GetCurrentBlitter();
	assert(blitter->GetScreenDepth() == 32);
	size_t buffer_size = _screen.pitch * _screen.height * 4;
	if (pixel_buffer) {
		free(pixel_buffer);
	}

#ifdef WITH_METAL
	// align buffer
	if (usingMetal && buffer_size % 4096) {
		buffer_size += (4096 - (buffer_size % 4096));
	}
#endif

	pixel_buffer = malloc(buffer_size*2);
	_screen.dst_ptr = pixel_buffer;
	
#ifdef WITH_METAL
	if (usingMetal) {
		CAMetalLayer *metalLayer = (CAMetalLayer *)_cocoa_touch_layer;
		metalLayer.drawableSize = CGSizeMake(w, h);
		
		MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
		screenBuffer = [metalLayer.device newBufferWithBytesNoCopy:pixel_buffer length:buffer_size options:MTLResourceOptionCPUCacheModeDefault deallocator:nil];
		screenTexture = [screenBuffer newTextureWithDescriptor:textureDescriptor offset:0 bytesPerRow:(_screen.pitch * 4)];
		
		BlitterFactory::GetCurrentBlitter()->PostResize();
		GameSizeChanged();
		return true;
	}
#endif
	
#ifdef WITH_OPENGL
	if ([_cocoa_touch_layer isKindOfClass:[CAEAGLLayer class]]) {
		BlitterFactory::GetCurrentBlitter()->PostResize();
		GameSizeChanged();
		return true;
	}
#endif
	
	// default to CoreGraphics
	int bitsPerComponent = 8;
	int bitsPerPixel = 32;
	int bytesPerRow = _screen.pitch * 4;
	CGBitmapInfo options = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
	CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
	if (this->context) {
		CGContextRelease(this->context);
	}
	this->context = CGBitmapContextCreate(pixel_buffer, _screen.width, _screen.height, bitsPerComponent, bytesPerRow, colorSpace, options);
	CGColorSpaceRelease(colorSpace);
	
	BlitterFactory::GetCurrentBlitter()->PostResize();
	GameSizeChanged();
	return true;
}

bool VideoDriver_CocoaTouch::ToggleFullscreen(bool fullsreen)
{
	return false;
}

bool VideoDriver_CocoaTouch::AfterBlitterChange()
{
	return this->ChangeResolution(_screen.width, _screen.height);
}

void VideoDriver_CocoaTouch::EditBoxLostFocus()
{
	HideOnScreenKeyboard();
}

void VideoDriver_CocoaTouch::Draw()
{
#ifdef WITH_METAL
	if ([_cocoa_touch_layer isKindOfClass:[CAMetalLayer class]]) {
		CAMetalLayer *metalLayer = (CAMetalLayer *)_cocoa_touch_layer;
		if (CGSizeEqualToSize(metalLayer.drawableSize, CGSizeZero)) {
			NSLog(@"The drawable's size is empty");
			return;
		}
		
		id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
		if (!drawable) {
			NSLog(@"The drawable cannot be nil");
			return;
		}
		
		MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor new];
		renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
		renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
		renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
		
		id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
		
		id<MTLRenderCommandEncoder> commandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
		[commandEncoder setRenderPipelineState:pipelineState];
		[commandEncoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
		[commandEncoder setFragmentTexture:screenTexture atIndex:0];
		[commandEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
		[commandEncoder endEncoding];
		
		[commandBuffer presentDrawable:drawable];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		return;
	}
#endif
	
#ifdef WITH_OPENGL
	if ([_cocoa_touch_layer isKindOfClass:[CAEAGLLayer class]]) {
		CAEAGLLayer *eaglLayer = (CAEAGLLayer *)_cocoa_touch_layer;
		if (![EAGLContext setCurrentContext:glContext])
			return;
		
		glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
		glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
		
		CGRect bounds = eaglLayer.bounds;
		CGFloat scale = eaglLayer.contentsScale;
		
		if (!CGRectEqualToRect(lastBounds, bounds)) {
			glDeleteRenderbuffers(1, &renderbuffer);
			glGenRenderbuffers(1, &renderbuffer);
			glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
			[glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:eaglLayer];
			glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);
			lastBounds = bounds;
		}
		
		glViewport(CGRectGetMinX(bounds) * scale, CGRectGetMinY(bounds) * scale, CGRectGetWidth(bounds) * scale, CGRectGetHeight(bounds) * scale);
		
		glBindBuffer(GL_ARRAY_BUFFER, glVertexBuffer);
		glVertexAttribPointer(positionSlot, 3, GL_FLOAT, GL_FALSE, sizeof(gl_vertex), 0);
		glVertexAttribPointer(texcoordSlot, 2, GL_FLOAT, GL_FALSE, sizeof(gl_vertex), (GLvoid *)(sizeof(float) * 3));
		
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_2D, glScreenTexture);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, _screen.pitch, _screen.height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixel_buffer);
		glUniform1i(textureUniform, 0);
		
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glBindBuffer(GL_ARRAY_BUFFER, 0);
		glBindTexture(GL_TEXTURE_2D, 0);
		
		[glContext presentRenderbuffer:GL_RENDERBUFFER];
		
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		glBindRenderbuffer(GL_RENDERBUFFER, 0);
		[EAGLContext setCurrentContext:nil];
		return;
	}
#endif
	
	// CoreGraphics
	CGImageRef screenImage = CGBitmapContextCreateImage(this->context);
	_cocoa_touch_layer.contents = (__bridge id)screenImage;
	CGImageRelease(screenImage);
}

void VideoDriver_CocoaTouch::UpdatePalette(uint first_color, uint num_colors)
{
	
}
