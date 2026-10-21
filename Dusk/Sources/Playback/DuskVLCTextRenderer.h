#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Sets libvlc `freetype-*` text renderer variables on a media player.
///
/// The video output and its text renderer are children of the libvlc media
/// player object, not of the input, so per-media `:freetype-…` options never
/// reach them. VLCKit 3.x's own text renderer setters only cover font, size,
/// colour and bold; everything else (opacity, background, outline, shadow) has
/// to be created as an inheritable variable on the player itself. The renderer
/// reads them when the next media opens. Each call returns NO when VLCKit no
/// longer exposes the player handle.
@interface DuskVLCTextRenderer : NSObject

+ (BOOL)setInteger:(int64_t)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;
+ (BOOL)setFloat:(float)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;
+ (BOOL)setString:(NSString *)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
