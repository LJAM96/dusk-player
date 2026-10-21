#import "DuskVLCTextRenderer.h"

#import <vlc/vlc.h>
#import <stdbool.h>
#import <stdint.h>

// Same private accessor DuskVLCRawVideoOutput uses for the raw libvlc handle.
@interface VLCMediaPlayer (DuskTextRendererBridge)
@property (nonatomic, readonly) libvlc_media_player_t *playerInstance;
@end

// libvlccore's variable API, exported by the vendored 3.x binaries but not part
// of the public libvlc headers. In libvlc 3.x a `libvlc_media_player_t` starts
// with the common vlc_object_t header, so the handle is a valid object here.
typedef union {
    int64_t i_int;
    bool b_bool;
    float f_float;
    char *psz_string;
    void *p_address;
    void *p_list;
    struct { int32_t x; int32_t y; } coords;
} DuskVLCValue;

extern int var_Create(void *object, const char *name, int type);
extern int var_Type(void *object, const char *name);
extern int var_SetChecked(void *object, const char *name, int type, DuskVLCValue value);

static const int DuskVLCVarInteger = 0x0030;
static const int DuskVLCVarString = 0x0040;
static const int DuskVLCVarFloat = 0x0050;
static const int DuskVLCVarDoInherit = 0x8000;

@implementation DuskVLCTextRenderer

+ (BOOL)set:(DuskVLCValue)value type:(int)type option:(NSString *)option player:(VLCMediaPlayer *)player
{
    if (![player respondsToSelector:@selector(playerInstance)]) {
        return NO;
    }
    void *object = player.playerInstance;
    if (object == NULL) {
        return NO;
    }
    const char *name = option.UTF8String;
    // var_Create is reference counted; create once per player, then just set.
    if (var_Type(object, name) == 0 && var_Create(object, name, type | DuskVLCVarDoInherit) != 0) {
        return NO;
    }
    return var_SetChecked(object, name, type, value) == 0;
}

+ (BOOL)setInteger:(int64_t)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player
{
    DuskVLCValue vlcValue = { .i_int = value };
    return [self set:vlcValue type:DuskVLCVarInteger option:option player:player];
}

+ (BOOL)setFloat:(float)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player
{
    DuskVLCValue vlcValue = { .f_float = value };
    return [self set:vlcValue type:DuskVLCVarFloat option:option player:player];
}

+ (BOOL)setString:(NSString *)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player
{
    // var_SetChecked copies the string.
    DuskVLCValue vlcValue = { .psz_string = (char *)value.UTF8String };
    return [self set:vlcValue type:DuskVLCVarString option:option player:player];
}

@end
