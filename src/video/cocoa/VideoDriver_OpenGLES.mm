//
//  VideoDriver_OpenGLES.m
//  OpenTTD_iOS
//
//  Created by Christian Skaarup Enevoldsen on 06/06/2022.
//

#import "VideoDriver_OpenGLES.h"

#include "ios_wnd.h"

#include "../../debug.h"
#include "../../core/geometry_func.hpp"
#include "../../core/math_func.hpp"

#include "../../blitter/factory.hpp"
#include "../../framerate_type.h"

#ifdef WITH_OPENGL
#import <OpenGLES/gltypes.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
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

static Palette _local_palette; ///< Current palette to use for drawing.

VideoDriver_OpenGLES *_cocoa_touch_driver = NULL;

@implementation OTTD_OpenGLESView

- (instancetype)initWithFrame:(CGRect)frameRect andDriver:(VideoDriver_OpenGLES *)drv
{
    if (self = [ super initWithFrame:frameRect ]) {
        self->driver = drv;

        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.opaque = YES;
    }
    return self;
}

- (BOOL)acceptsFirstResponder
{
    return NO;
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)wantsUpdateLayer
{
    return YES;
}

- (void)updateLayer
{
    if (driver->context == nullptr) return;

    /* Set layer contents to our backing buffer, which avoids needless copying. */
    CGImageRef fullImage = CGBitmapContextCreateImage(driver->context);
    self.layer.contents = (__bridge id)fullImage;
    CGImageRelease(fullImage);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    if ([self.layer.sublayers containsObject:_cocoa_touch_layer] == false) {
        _cocoa_touch_layer.frame = self.bounds;
        [self.layer addSublayer:_cocoa_touch_layer];
    }
    
    _cocoa_touch_layer.frame = self.bounds;
}

@end


static FVideoDriver_OpenGLES iFVideoDriver_OpenGLES;

/** Clear buffer to opaque black. */
static void ClearWindowBuffer(uint32 *buffer, uint32 pitch, uint32 height)
{
    uint32 fill = Colour(0, 0, 0).data;
    for (uint32 y = 0; y < height; y++) {
        for (uint32 x = 0; x < pitch; x++) {
            buffer[y * pitch + x] = fill;
        }
    }
}

VideoDriver_OpenGLES::VideoDriver_OpenGLES()
{
    this->window_width  = 0;
    this->window_height = 0;
    this->window_pitch  = 0;
    this->buffer_depth  = 0;
    this->pixel_buffer  = nullptr;

    this->context     = nullptr;
}

const char *VideoDriver_OpenGLES::Start(const StringList &param)
{
    _cocoa_touch_driver = this;
    
    const char *err = this->Initialize();
    if (err != nullptr) return err;

    int bpp = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();
    if (bpp != 8 && bpp != 32) {
        Stop();
        return "The cocoa quartz subdriver only supports 8 and 32 bpp.";
    }

    bool fullscreen = _fullscreen;
    if (!this->MakeWindow(_cur_resolution.width, _cur_resolution.height)) {
        Stop();
        return "Could not create window";
    }
    
    this->OpenGLStart();

    this->AllocateBackingStore(true);

    if (fullscreen) this->ToggleFullscreen(fullscreen);

    this->GameSizeChanged();
    this->UpdateVideoModes();

    this->is_game_threaded = !GetDriverParamBool(param, "no_threads") && !GetDriverParamBool(param, "no_thread");

    return nullptr;

}

void VideoDriver_OpenGLES::Stop()
{
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
    
    _cocoa_touch_driver = NULL;
    
    this->VideoDriver_Cocoa::Stop();

    CGContextRelease(this->context);

    free(this->pixel_buffer);
}

UIView *VideoDriver_OpenGLES::AllocateDrawView()
{
    return [ [ OTTD_OpenGLESView alloc ] initWithFrame:[ this->cocoaview bounds ] andDriver:this ];
}

/** Resize the window. */
void VideoDriver_OpenGLES::AllocateBackingStore(bool force)
{
    if (this->window == nil || this->cocoaview == nil || this->setup) return;

    this->UpdatePalette(0, 256);

    CGRect newframe = [this->cocoaview getRealRect:[this->cocoaview bounds]];
    
    this->window_width = (int)newframe.size.width;
    this->window_height = (int)newframe.size.height;
    this->window_pitch = Align(this->window_width, 16 / sizeof(uint32)); // Quartz likes lines that are multiple of 16-byte.
    this->buffer_depth = BlitterFactory::GetCurrentBlitter()->GetScreenDepth();

    /* Create Core Graphics Context */
    free(this->pixel_buffer);
    this->pixel_buffer = malloc(this->window_pitch * this->window_height * sizeof(uint32));
    /* Initialize with opaque black. */
    ClearWindowBuffer((uint32 *)this->pixel_buffer, this->window_pitch, this->window_height);

    
#ifdef WITH_OPENGL
    if ([_cocoa_touch_layer isKindOfClass:[CAEAGLLayer class]]) {
        BlitterFactory::GetCurrentBlitter()->PostResize();
        GameSizeChanged();
    }
#else
    int bitsPerComponent = 8;
    int bytesPerRow = window_pitch * 4;
    CGBitmapInfo options = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (this->context) {
        CGContextRelease(this->context);
    }
    this->context = CGBitmapContextCreate(pixel_buffer, window_width, window_height, bitsPerComponent, bytesPerRow, colorSpace, options);
    CGColorSpaceRelease(colorSpace);
#endif

    /* Tell the game that the resolution has changed */
    _screen.width   = this->window_width;
    _screen.height  = this->window_height;
    _screen.pitch   = this->buffer_depth == 8 ? this->window_width : this->window_pitch;
    _screen.dst_ptr = this->GetVideoPointer();

    UIEdgeInsets safeAreaInsets = this->window.safeAreaInsets;
    
    CGFloat offset = MAX(safeAreaInsets.top, MAX(safeAreaInsets.left, safeAreaInsets.right));
    
    _settings_client.gui.toolbar_pos = 3;
    _settings_client.gui.toolbar_pos_offset = this->isLandscape ? 1 : offset;
    
    _settings_client.gui.statusbar_pos = 4;
    _settings_client.gui.statusbar_pos_offset = this->window.safeAreaInsets.bottom;
    
    /* Redraw screen */
    this->MakeDirty(0, 0, _screen.width , _screen.height);
    this->GameSizeChanged();
}

/**
 * This function copies 8bpp pixels from the screen buffer in 32bpp windowed mode.
 *
 * @param left The x coord for the left edge of the box to blit.
 * @param top The y coord for the top edge of the box to blit.
 * @param right The x coord for the right edge of the box to blit.
 * @param bottom The y coord for the bottom edge of the box to blit.
 */
void VideoDriver_OpenGLES::BlitIndexedToView32(int left, int top, int right, int bottom)
{
    const uint32 *pal   = this->palette;
    const uint32  *src   = (uint32*)this->pixel_buffer;
    uint32       *dst   = (uint32*)this->pixel_buffer;
    uint          width = this->window_width;
    uint          pitch = this->window_pitch;

    for (int y = top; y < bottom; y++) {
        for (int x = left; x < right; x++) {
            dst[y * pitch + x] = pal[src[y * width + x]];
        }
    }
}

/** Update the palette */
void VideoDriver_OpenGLES::UpdatePalette(uint first_color, uint num_colors)
{
    if (this->buffer_depth != 8) return;

    for (uint i = first_color; i < first_color + num_colors; i++) {
        uint32 clr = 0xff000000;
        clr |= (uint32)_local_palette.palette[i].r << 16;
        clr |= (uint32)_local_palette.palette[i].g << 8;
        clr |= (uint32)_local_palette.palette[i].b;
        this->palette[i] = clr;
    }

    this->MakeDirty(0, 0, _screen.width, _screen.height);
}

void VideoDriver_OpenGLES::CheckPaletteAnim()
{
    if (!CopyPalette(_local_palette)) return;

    Blitter *blitter = BlitterFactory::GetCurrentBlitter();

    switch (blitter->UsePaletteAnimation()) {
        case Blitter::PALETTE_ANIMATION_VIDEO_BACKEND:
            this->UpdatePalette(_local_palette.first_dirty, _local_palette.count_dirty);
            break;

        case Blitter::PALETTE_ANIMATION_BLITTER:
            blitter->PaletteAnimate(_local_palette);
            break;

        case Blitter::PALETTE_ANIMATION_NONE:
            break;

        default:
            NOT_REACHED();
    }
}

/** Draw window */
void VideoDriver_OpenGLES::Paint()
{
    PerformanceMeasurer framerate(PFE_VIDEO);

    /* Check if we need to do anything */
    if (IsEmptyRect(this->dirty_rect)) return; /* || [ this->window isMiniaturized ] */

    /* We only need to blit in indexed mode since in 32bpp mode the game draws directly to the image. */
    if (this->buffer_depth == 8) {
        BlitIndexedToView32(
            this->dirty_rect.left,
            this->dirty_rect.top,
            this->dirty_rect.right,
            this->dirty_rect.bottom
        );
    }

    CGRect dirtyrect;
    dirtyrect.origin.x = this->dirty_rect.left;
    dirtyrect.origin.y = this->window_height - this->dirty_rect.bottom;
    dirtyrect.size.width = this->dirty_rect.right - this->dirty_rect.left;
    dirtyrect.size.height = this->dirty_rect.bottom - this->dirty_rect.top;

    this->Draw();
    
    dispatch_async(dispatch_get_main_queue(), ^{
        /* Notify OS X that we have new content to show. */
        [ this->cocoaview setNeedsDisplayInRect:[ this->cocoaview getVirtualRect:dirtyrect ] ];
        
        /* Tell the OS to get our contents to screen as soon as possible. */
        [ CATransaction flush ];
    });
    
    this->dirty_rect = {};
}

void VideoDriver_OpenGLES::Draw()
{
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

void VideoDriver_OpenGLES::OpenGLStart() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{@"Video": @"metal",
                                 @"NativeResolution": @NO}];
    _fullscreen = true;
    
    NSString *selectedDriver = [defaults stringForKey:@"Video"];
    
#ifdef WITH_OPENGL
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
}


void VideoDriver_OpenGLES::OpenGLTick() {
    
//    _settings_client.gui.toolbar_pos = 3;
//    _settings_client.gui.toolbar_pos_offset = this->isLandscape ? 0 : this->window.safeAreaInsets.top;
//
//    _settings_client.gui.statusbar_pos = 4;
//    _settings_client.gui.statusbar_pos_offset = this->window.safeAreaInsets.bottom;
    
    @autoreleasepool {
        this->Tick();
        this->SleepTillNextTick();
    }
}

void VideoDriver_OpenGLES::OpenGLStartGame() {
    this->StartGameThread();
}

void VideoDriver_OpenGLES::OpenGLStopGame() {
    this->StopGameThread();
}
