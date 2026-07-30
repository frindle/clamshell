#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirrors PROTOCOL.md's mouse button numbering (0=left, 1=right) plus
/// middle, so RDPSession.swift can reuse the same button constants the
/// Clamshell-protocol path already uses in VideoView.
typedef NS_ENUM(NSInteger, RDPMouseButton) {
    RDPMouseButtonLeft = 0,
    RDPMouseButtonRight = 1,
    RDPMouseButtonMiddle = 2,
};

/// Thin Objective-C wrapper around libfreerdp's client C API (rdpContext /
/// freerdp_connect / freerdp_input_send_*), in the same spirit as
/// CGVirtualDisplayShim: hide a non-Swift-friendly C API behind one small
/// Obj-C surface. Unlike CGVirtualDisplayShim this one has real logic behind
/// it (FreeRDP has no Swift-friendly shape at all), so it's not header-only.
///
/// One instance = one connection attempt. Create a new instance to
/// reconnect; instances are not reusable after -stop.
@interface RDPBridgeSession : NSObject

- (instancetype)initWithHost:(NSString *)host
                         port:(uint16_t)port
                     username:(NSString *)username
                     password:(NSString *)password
                       domain:(nullable NSString *)domain
                        width:(int)width
                       height:(int)height
             ignoreCertErrors:(BOOL)ignoreCertErrors NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Fires once the handshake completes and the first framebuffer exists.
/// width/height are the server-negotiated desktop size, which can differ
/// from the requested size. Called on a private background queue.
@property (nonatomic, copy, nullable) void (^onConnected)(int width, int height);

/// Fires on every composited framebuffer update. `image` is the *whole*
/// desktop framebuffer, not just the dirty rect — FreeRDP's GDI backend
/// keeps one composited buffer and this is the simplest correct way to read
/// it back; a dirty-rect-only path is the natural perf upgrade if full-frame
/// CGImage churn shows up in profiling. Called on a private background
/// queue — hop to main before touching UIKit.
@property (nonatomic, copy, nullable) void (^onFrameUpdate)(CGImageRef image);

/// Fires exactly once when the session ends, for any reason (clean
/// disconnect, auth failure, network error). `errorMessage` is nil only for
/// a clean, caller-initiated -stop.
@property (nonatomic, copy, nullable) void (^onDisconnected)(NSString * _Nullable errorMessage);

/// Fires when the server rejects the certificate and wants a yes/no
/// decision. `subject`/`issuer`/`fingerprint` are for display; call the
/// completion with the user's answer. If this block is nil, unverifiable
/// certs are rejected (safe default) unless ignoreCertErrors was set.
@property (nonatomic, copy, nullable) void (^onCertificateVerify)
    (NSString *subject, NSString *issuer, NSString *fingerprint, void (^completion)(BOOL accept));

/// Starts the connection on a background thread. Non-blocking; returns
/// immediately. Safe to call once per instance.
- (void)start;

/// Tears down the connection. Safe to call from any thread, safe to call
/// more than once (subsequent calls are no-ops).
- (void)stop;

// MARK: Input — all coordinates normalized 0..1 over the connected desktop
// size, matching StreamClient's INPUT_MOUSE_MOVE convention so RDPView can
// reuse VideoView's touch-normalization code unchanged.

- (void)sendMouseMoveX:(float)x y:(float)y;
- (void)sendMouseButton:(RDPMouseButton)button down:(BOOL)down x:(float)x y:(float)y;
/// Positive dy = wheel down (content scrolls down), matching StreamClient's
/// INPUT_SCROLL sign convention.
- (void)sendScrollDeltaY:(float)dy;

/// Raw PC/AT "Set 1" scancode (what RDP actually transmits), plus the
/// extended-key flag for the E0-prefixed keys (arrows, right-Alt/Ctrl, etc).
/// See RDPKeyMap.swift for the HID -> scancode table.
- (void)sendScancode:(uint16_t)scancode extended:(BOOL)extended down:(BOOL)down;

/// Unicode key event, for characters with no direct scancode (used by any
/// future software-keyboard/IME path — physical keyboard passthrough should
/// prefer -sendScancode:extended:down: since it round-trips modifier state
/// correctly).
- (void)sendUnicodeCharacter:(uint16_t)utf16Char down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
