//
//  ios_keys.h
//  OpenTTD
//
//  Created by Christian Skaarup Enevoldsen on 28/06/2022.
//

#ifndef ios_keys_h
#define ios_keys_h

#define IOS_ESCAPE       0x29
#define IOS_F1           0x3A
#define IOS_F2           0x3B
#define IOS_F3           0x3C
#define IOS_F4           0x3D
#define IOS_F5           0x3E
#define IOS_F6           0x3F
#define IOS_F7           0x40
#define IOS_F8           0x41
#define IOS_F9           0x42
#define IOS_F10          0x43
#define IOS_F11          0x44
#define IOS_F12          0x45
#define IOS_PRINT        0x69
#define IOS_SCROLLOCK    0x6B
#define IOS_PAUSE        0x71
#define IOS_POWER        0x7F
#define IOS_BACKQUOTE    0x2E
#define IOS_BACKQUOTE2   0x32
#define IOS_1            0x1E
#define IOS_2            0x1F
#define IOS_3            0x20
#define IOS_4            0x21
#define IOS_5            0x22
#define IOS_6            0x23
#define IOS_7            0x24
#define IOS_8            0x25
#define IOS_9            0x26
#define IOS_0            0x27
#define IOS_MINUS        0x38
#define IOS_EQUALS       0x18
#define IOS_BACKSPACE    0x2A
#define IOS_INSERT       0x72
#define IOS_HOME         0x73
#define IOS_PAGEUP       0x74
#define IOS_NUMLOCK      0x47
#define IOS_KP_EQUALS    0x51
#define IOS_KP_DIVIDE    0x4B
#define IOS_KP_MULTIPLY  0x43
#define IOS_TAB          0x2B
#define IOS_q            0x14
#define IOS_w            0x1A
#define IOS_e            0x08
#define IOS_r            0x15
#define IOS_t            0x17
#define IOS_y            0x1C
#define IOS_u            0x18
#define IOS_i            0x0C
#define IOS_o            0x12
#define IOS_p            0x13
#define IOS_LEFTBRACKET  0x21
#define IOS_RIGHTBRACKET 0x1E
#define IOS_BACKSLASH    0x2A
#define IOS_DELETE       0x4C
#define IOS_END          0x77
#define IOS_PAGEDOWN     0x79
#define IOS_KP7          0x59
#define IOS_KP8          0x5B
#define IOS_KP9          0x5C
#define IOS_KP_MINUS     0x4E
#define IOS_CAPSLOCK     0x39
#define IOS_a            0x04
#define IOS_s            0x16
#define IOS_d            0x07
#define IOS_f            0x09
#define IOS_g            0x0A
#define IOS_h            0x0B
#define IOS_j            0x0D
#define IOS_k            0x0E
#define IOS_l            0x0F
#define IOS_SEMICOLON    0x29
#define IOS_QUOTE        0x27
#define IOS_RETURN       0x28
#define IOS_KP4          0x56
#define IOS_KP5          0x57
#define IOS_KP6          0x58
#define IOS_KP_PLUS      0x45
#define IOS_LSHIFT       0xE1
#define IOS_z            0x1D
#define IOS_x            0x1B
#define IOS_c            0x06
#define IOS_v            0x19
#define IOS_b            0x05
#define IOS_n            0x11
#define IOS_m            0x10
#define IOS_COMMA        0x36
#define IOS_PERIOD       0x37
#define IOS_SLASH        0x2C
#if 1        /* Panther now defines right side keys */
#define IOS_RSHIFT       0xE5
#endif
#define IOS_UP           0x52
#define IOS_KP1          0x53
#define IOS_KP2          0x54
#define IOS_KP3          0x55
#define IOS_KP_ENTER     0x4C
#define IOS_LCTRL        0xE0
#define IOS_LALT         0xE2
#define IOS_LMETA        0xE3
#define IOS_SPACE        0x2C
#if 1        /* Panther now defines right side keys */
#define IOS_RMETA        0xE7
#define IOS_RALT         0xE6
#define IOS_RCTRL        0xE4
#endif
#define IOS_LEFT         0x50
#define IOS_DOWN         0x51
#define IOS_RIGHT        0x4F
#define IOS_KP0          0x52
#define IOS_KP_PERIOD    0x41

/* Weird, these keys are on my iBook under MacOS X */
#define IOS_IBOOK_ENTER  0x34
#define IOS_IBOOK_LEFT   0x3B
#define IOS_IBOOK_RIGHT  0x3C
#define IOS_IBOOK_DOWN   0x3D
#define IOS_IBOOK_UP     0x3E


int OTTD_EventModifierFlagCommand = 1114112;
int OTTD_EventModifierFlagControl = 327680;
int OTTD_EventModifierFlagOption = 589824;
int OTTD_EventModifierFlagShift = 196608;

struct IOSVkMapping {
    unsigned short vk_from;
    byte map_to;
};

#define AS(x, z) {x, z}

static const IOSVkMapping _vk_mapping[] = {
    AS(IOS_BACKQUOTE,  WKC_BACKQUOTE), // key left of '1'
    AS(IOS_BACKQUOTE2, WKC_BACKQUOTE), // some keyboards have it on another scancode

    /* Pageup stuff + up/down */
    AS(IOS_PAGEUP,   WKC_PAGEUP),
    AS(IOS_PAGEDOWN, WKC_PAGEDOWN),

    AS(IOS_UP,    WKC_UP),
    AS(IOS_DOWN,  WKC_DOWN),
    AS(IOS_LEFT,  WKC_LEFT),
    AS(IOS_RIGHT, WKC_RIGHT),

    AS(IOS_HOME, WKC_HOME),
    AS(IOS_END,  WKC_END),

    AS(IOS_INSERT, WKC_INSERT),
    AS(IOS_DELETE, WKC_DELETE),

    /* Letters. IOS_[a-z] is not in numerical order so we can't use AM(...) */
    AS(IOS_a, 'A'),
    AS(IOS_b, 'B'),
    AS(IOS_c, 'C'),
    AS(IOS_d, 'D'),
    AS(IOS_e, 'E'),
    AS(IOS_f, 'F'),
    AS(IOS_g, 'G'),
    AS(IOS_h, 'H'),
    AS(IOS_i, 'I'),
    AS(IOS_j, 'J'),
    AS(IOS_k, 'K'),
    AS(IOS_l, 'L'),
    AS(IOS_m, 'M'),
    AS(IOS_n, 'N'),
    AS(IOS_o, 'O'),
    AS(IOS_p, 'P'),
    AS(IOS_q, 'Q'),
    AS(IOS_r, 'R'),
    AS(IOS_s, 'S'),
    AS(IOS_t, 'T'),
    AS(IOS_u, 'U'),
    AS(IOS_v, 'V'),
    AS(IOS_w, 'W'),
    AS(IOS_x, 'X'),
    AS(IOS_y, 'Y'),
    AS(IOS_z, 'Z'),
    /* Same thing for digits */
    AS(IOS_0, '0'),
    AS(IOS_1, '1'),
    AS(IOS_2, '2'),
    AS(IOS_3, '3'),
    AS(IOS_4, '4'),
    AS(IOS_5, '5'),
    AS(IOS_6, '6'),
    AS(IOS_7, '7'),
    AS(IOS_8, '8'),
    AS(IOS_9, '9'),

    AS(IOS_ESCAPE,    WKC_ESC),
    AS(IOS_PAUSE,     WKC_PAUSE),
    AS(IOS_BACKSPACE, WKC_BACKSPACE),

    AS(IOS_SPACE,  WKC_SPACE),
    AS(IOS_RETURN, WKC_RETURN),
    AS(IOS_TAB,    WKC_TAB),

    /* Function keys */
    AS(IOS_F1,  WKC_F1),
    AS(IOS_F2,  WKC_F2),
    AS(IOS_F3,  WKC_F3),
    AS(IOS_F4,  WKC_F4),
    AS(IOS_F5,  WKC_F5),
    AS(IOS_F6,  WKC_F6),
    AS(IOS_F7,  WKC_F7),
    AS(IOS_F8,  WKC_F8),
    AS(IOS_F9,  WKC_F9),
    AS(IOS_F10, WKC_F10),
    AS(IOS_F11, WKC_F11),
    AS(IOS_F12, WKC_F12),

    /* Numeric part */
    AS(IOS_KP0,         '0'),
    AS(IOS_KP1,         '1'),
    AS(IOS_KP2,         '2'),
    AS(IOS_KP3,         '3'),
    AS(IOS_KP4,         '4'),
    AS(IOS_KP5,         '5'),
    AS(IOS_KP6,         '6'),
    AS(IOS_KP7,         '7'),
    AS(IOS_KP8,         '8'),
    AS(IOS_KP9,         '9'),
    AS(IOS_KP_DIVIDE,   WKC_NUM_DIV),
    AS(IOS_KP_MULTIPLY, WKC_NUM_MUL),
    AS(IOS_KP_MINUS,    WKC_NUM_MINUS),
    AS(IOS_KP_PLUS,     WKC_NUM_PLUS),
    AS(IOS_KP_ENTER,    WKC_NUM_ENTER),
    AS(IOS_KP_PERIOD,   WKC_NUM_DECIMAL),

    /* Other non-letter keys */
    AS(IOS_SLASH,        WKC_SLASH),
    AS(IOS_SEMICOLON,    WKC_SEMICOLON),
    AS(IOS_EQUALS,       WKC_EQUALS),
    AS(IOS_LEFTBRACKET,  WKC_L_BRACKET),
    AS(IOS_BACKSLASH,    WKC_BACKSLASH),
    AS(IOS_RIGHTBRACKET, WKC_R_BRACKET),

    AS(IOS_QUOTE,   WKC_SINGLEQUOTE),
    AS(IOS_COMMA,   WKC_COMMA),
    AS(IOS_MINUS,   WKC_MINUS),
    AS(IOS_PERIOD,  WKC_PERIOD)
};

#undef AS

#endif /* ios_keys_h */
