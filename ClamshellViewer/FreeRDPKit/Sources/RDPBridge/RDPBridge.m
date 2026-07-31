#import "include/RDPBridge.h"

#import <freerdp/config.h>
#import <freerdp/freerdp.h>
#import <freerdp/client.h>
#import <freerdp/gdi/gdi.h>
#import <freerdp/input.h>
#import <winpr/synch.h>
#import <winpr/crt.h>

// Custom client context, same shape as FreeRDP's own reference clients
// (client/Sample/tf_freerdp.h): rdpClientContext must be the first member so
// a pointer to this struct is also a valid rdpContext* / rdpClientContext*
// (C's common-initial-sequence rule — every FreeRDP client does this).
typedef struct
{
    rdpClientContext common;
    void *bridge; // (__bridge RDPBridgeSession *) — the owning Obj-C instance
} ClamshellRdpContext;

static ClamshellRdpContext *ClamshellCtx(rdpContext *context)
{
    return (ClamshellRdpContext *)context;
}

@interface RDPBridgeSession ()
@property (nonatomic, strong) NSString *host;
@property (nonatomic) uint16_t port;
@property (nonatomic, strong) NSString *username;
@property (nonatomic, strong) NSString *password;
@property (nonatomic, strong, nullable) NSString *domain;
@property (nonatomic) int width;
@property (nonatomic) int height;
@property (nonatomic) BOOL ignoreCertErrors;
@property (nonatomic) int desktopWidth;
@property (nonatomic) int desktopHeight;
@property (nonatomic, nullable) freerdp *instance;
@property (nonatomic, nullable) NSThread *connectionThread;
@property (atomic) BOOL stopping;
@end

@implementation RDPBridgeSession

- (instancetype)initWithHost:(NSString *)host
                         port:(uint16_t)port
                     username:(NSString *)username
                     password:(NSString *)password
                       domain:(nullable NSString *)domain
                        width:(int)width
                       height:(int)height
             ignoreCertErrors:(BOOL)ignoreCertErrors
{
    if ((self = [super init])) {
        _host = host;
        _port = port;
        _username = username;
        _password = password;
        _domain = domain;
        _width = width;
        _height = height;
        _ignoreCertErrors = ignoreCertErrors;
    }
    return self;
}

#pragma mark - FreeRDP callbacks (C, no Obj-C context — go through ->bridge)

static BOOL clamshell_begin_paint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL clamshell_end_paint(rdpContext *context)
{
    ClamshellRdpContext *ctx = ClamshellCtx(context);
    RDPBridgeSession *session = (__bridge RDPBridgeSession *)ctx->bridge;
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer || !session.onFrameUpdate) return TRUE;

    // Copy out: gdi->primary_buffer is FreeRDP's own buffer and gets mutated
    // on the next frame, so CGImage needs its own copy of the bytes rather
    // than wrapping FreeRDP's memory directly.
    size_t length = (size_t)gdi->stride * (size_t)gdi->height;
    NSData *data = [NSData dataWithBytes:gdi->primary_buffer length:length];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    // PIXEL_FORMAT_BGRA32 (set in gdi_init below) = byte order B,G,R,A in
    // memory, which is exactly kCGBitmapByteOrder32Little +
    // kCGImageAlphaNoneSkipFirst (alpha ignored — FreeRDP's framebuffer has
    // no meaningful alpha channel).
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGImageRef image = CGImageCreate((size_t)gdi->width, (size_t)gdi->height, 8, 32,
                                     gdi->stride, colorSpace, bitmapInfo, provider,
                                     NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    if (image) {
        session.onFrameUpdate(image);
        CGImageRelease(image);
    }
    return TRUE;
}

static BOOL clamshell_desktop_resize(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    rdpSettings *settings = context->settings;
    ClamshellRdpContext *ctx = ClamshellCtx(context);
    RDPBridgeSession *session = (__bridge RDPBridgeSession *)ctx->bridge;
    UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    session.desktopWidth = (int)w;
    session.desktopHeight = (int)h;
    return gdi_resize(gdi, w, h);
}

static DWORD clamshell_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                             const char *common_name, const char *subject,
                                             const char *issuer, const char *fingerprint,
                                             DWORD flags)
{
    ClamshellRdpContext *ctx = ClamshellCtx(instance->context);
    RDPBridgeSession *session = (__bridge RDPBridgeSession *)ctx->bridge;
    if (session.ignoreCertErrors) return 2; // accept, this session only

    void (^verify)(NSString *, NSString *, NSString *, void (^)(BOOL)) = session.onCertificateVerify;
    if (!verify) return 0; // no UI wired up: reject unverifiable certs (safe default)

    NSString *subjectStr = subject ? @(subject) : @"";
    NSString *issuerStr = issuer ? @(issuer) : @"";
    NSString *fingerprintStr = fingerprint ? @(fingerprint) : @"";

    // FreeRDP's callback is synchronous (called from the connection thread,
    // blocking the handshake), but the decision needs a human tap. Block
    // this thread on a semaphore until RDPSession.swift's completion fires.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL accepted = NO;
    verify(subjectStr, issuerStr, fingerprintStr, ^(BOOL accept) {
        accepted = accept;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return accepted ? 2 : 0;
}

static BOOL clamshell_pre_connect(freerdp *instance)
{
    rdpSettings *settings = instance->context->settings;
    if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE)) return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_UNIX)) return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_NATIVE_XSERVER)) return FALSE;
    return TRUE;
}

static BOOL clamshell_post_connect(freerdp *instance)
{
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;

    rdpContext *context = instance->context;
    ClamshellRdpContext *ctx = ClamshellCtx(context);
    RDPBridgeSession *session = (__bridge RDPBridgeSession *)ctx->bridge;

    context->update->BeginPaint = clamshell_begin_paint;
    context->update->EndPaint = clamshell_end_paint;
    context->update->DesktopResize = clamshell_desktop_resize;

    rdpGdi *gdi = context->gdi;
    session.desktopWidth = gdi->width;
    session.desktopHeight = gdi->height;
    if (session.onConnected) session.onConnected(gdi->width, gdi->height);
    return TRUE;
}

static void clamshell_post_disconnect(freerdp *instance)
{
    if (!instance || !instance->context) return;
    gdi_free(instance);
}

static BOOL clamshell_client_new(freerdp *instance, rdpContext *context)
{
    if (!instance || !context) return FALSE;
    instance->PreConnect = clamshell_pre_connect;
    instance->PostConnect = clamshell_post_connect;
    instance->PostDisconnect = clamshell_post_disconnect;
    instance->VerifyCertificateEx = clamshell_verify_certificate_ex;
    return TRUE;
}

static void clamshell_client_free(freerdp *instance, rdpContext *context)
{
    (void)instance;
    (void)context;
}

#pragma mark - Connection lifecycle

- (void)start
{
    self.stopping = NO;
    self.connectionThread = [[NSThread alloc] initWithTarget:self selector:@selector(runConnectionThread) object:nil];
    self.connectionThread.name = @"com.frindle.clamshell.rdp";
    self.connectionThread.stackSize = 1 << 20;
    [self.connectionThread start];
}

- (void)runConnectionThread
{
    RDP_CLIENT_ENTRY_POINTS entryPoints;
    ZeroMemory(&entryPoints, sizeof(entryPoints));
    entryPoints.Version = RDP_CLIENT_INTERFACE_VERSION;
    entryPoints.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entryPoints.ContextSize = sizeof(ClamshellRdpContext);
    entryPoints.ClientNew = clamshell_client_new;
    entryPoints.ClientFree = clamshell_client_free;

    rdpContext *context = freerdp_client_context_new(&entryPoints);
    if (!context) {
        [self reportDisconnected:@"Failed to allocate FreeRDP client context"];
        return;
    }
    ClamshellCtx(context)->bridge = (__bridge void *)self;

    rdpSettings *settings = context->settings;
    BOOL ok = YES;
    ok &= freerdp_settings_set_string(settings, FreeRDP_ServerHostname, self.host.UTF8String);
    ok &= freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, self.port);
    ok &= freerdp_settings_set_string(settings, FreeRDP_Username, self.username.UTF8String);
    ok &= freerdp_settings_set_string(settings, FreeRDP_Password, self.password.UTF8String);
    if (self.domain.length > 0) {
        ok &= freerdp_settings_set_string(settings, FreeRDP_Domain, self.domain.UTF8String);
    }
    ok &= freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)self.width);
    ok &= freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)self.height);
    ok &= freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32);
    ok &= freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, self.ignoreCertErrors);
    ok &= freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, NO);
    // NLA (CredSSP) first, falling back to plain TLS — matches every modern
    // Windows RDP host's default security layer negotiation.
    ok &= freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE);
    ok &= freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
    ok &= freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, TRUE);

    if (!ok) {
        freerdp_client_context_free(context);
        [self reportDisconnected:@"Failed to apply connection settings"];
        return;
    }

    self.instance = context->instance;

    if (!freerdp_connect(context->instance)) {
        UINT32 err = freerdp_get_last_error(context);
        NSString *msg = [NSString stringWithUTF8String:freerdp_get_last_error_string(err) ?: "connection failed"];
        freerdp_client_context_free(context);
        self.instance = NULL;
        [self reportDisconnected:msg];
        return;
    }

    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {0};
    while (!self.stopping && !freerdp_shall_disconnect_context(context)) {
        DWORD nCount = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
        if (nCount == 0) break;
        DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 100);
        if (status == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(context)) break;
    }

    NSString *errorMessage = nil;
    if (!self.stopping) {
        UINT32 err = freerdp_get_last_error(context);
        if (err != FREERDP_ERROR_SUCCESS && err != FREERDP_ERROR_NONE) {
            const char *str = freerdp_get_last_error_string(err);
            errorMessage = str ? [NSString stringWithUTF8String:str] : @"connection lost";
        }
    }

    freerdp_disconnect(context->instance);
    freerdp_client_context_free(context);
    self.instance = NULL;
    [self reportDisconnected:errorMessage];
}

- (void)reportDisconnected:(nullable NSString *)errorMessage
{
    if (self.onDisconnected) self.onDisconnected(errorMessage);
}

- (void)stop
{
    self.stopping = YES;
    if (self.instance && self.instance->context) {
        freerdp_abort_connect_context(self.instance->context);
    }
}

#pragma mark - Input

- (void)sendMouseMoveX:(float)x y:(float)y
{
    if (!self.instance || !self.instance->context) return;
    UINT16 px = (UINT16)(x * (float)self.desktopWidth);
    UINT16 py = (UINT16)(y * (float)self.desktopHeight);
    freerdp_input_send_mouse_event(self.instance->context->input, PTR_FLAGS_MOVE, px, py);
}

- (void)sendMouseButton:(RDPMouseButton)button down:(BOOL)down x:(float)x y:(float)y
{
    if (!self.instance || !self.instance->context) return;
    UINT16 px = (UINT16)(x * (float)self.desktopWidth);
    UINT16 py = (UINT16)(y * (float)self.desktopHeight);
    UINT16 flags = down ? PTR_FLAGS_DOWN : 0;
    switch (button) {
        case RDPMouseButtonLeft: flags |= PTR_FLAGS_BUTTON1; break;
        case RDPMouseButtonRight: flags |= PTR_FLAGS_BUTTON2; break;
        case RDPMouseButtonMiddle: flags |= PTR_FLAGS_BUTTON3; break;
    }
    freerdp_input_send_mouse_event(self.instance->context->input, flags, px, py);
}

- (void)sendScrollDeltaY:(float)dy
{
    if (!self.instance || !self.instance->context) return;
    // RDP wheel step is a signed 9-bit rotation magnitude in the low byte;
    // PTR_FLAGS_WHEEL_NEGATIVE flips the sign. One "click" ~= 120, matching
    // the usual mouse-wheel notch — scale the pixel delta into that range.
    int step = (int)(dy * (120.0f / 40.0f));
    if (step == 0) return;
    UINT16 flags = PTR_FLAGS_WHEEL;
    if (step < 0) { flags |= PTR_FLAGS_WHEEL_NEGATIVE; step = -step; }
    if (step > 0xFF) step = 0xFF;
    flags |= (UINT16)(step & WheelRotationMask);
    freerdp_input_send_mouse_event(self.instance->context->input, flags, 0, 0);
}

- (void)sendScancode:(uint16_t)scancode extended:(BOOL)extended down:(BOOL)down
{
    if (!self.instance || !self.instance->context) return;
    // KBD_FLAGS_DOWN is misleadingly named in FreeRDP's own header — it
    // actually means "was already down" (autorepeat), not "this is a
    // key-down event". A press is flags=0; only release sets a flag
    // (KBD_FLAGS_RELEASE). Extended (E0-prefixed) keys OR in KBD_FLAGS_EXTENDED
    // regardless of up/down.
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    if (extended) flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(self.instance->context->input, flags, (UINT8)scancode);
}

- (void)sendUnicodeCharacter:(uint16_t)utf16Char down:(BOOL)down
{
    if (!self.instance || !self.instance->context) return;
    UINT16 flags = down ? 0 : KBD_FLAGS_RELEASE;
    freerdp_input_send_unicode_keyboard_event(self.instance->context->input, flags, utf16Char);
}

@end
