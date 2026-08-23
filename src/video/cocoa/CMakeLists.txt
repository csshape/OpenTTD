add_files(
    cocoa_keys.h
    cocoa_v.h
    cocoa_v.mm
    cocoa_wnd.h
    cocoa_wnd.mm
    CONDITION APPLE AND NOT OTTD_APPLE_IOS
)

add_files(
    cocoa_ogl.h
    cocoa_ogl.mm
    CONDITION APPLE AND NOT OTTD_APPLE_IOS AND OPENGL_FOUND
)

add_files(
    cocoa_met.h
    cocoa_met.mm
    CONDITION APPLE AND NOT OTTD_APPLE_IOS AND METAL_LIBRARY
)
