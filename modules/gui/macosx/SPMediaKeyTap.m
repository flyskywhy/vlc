/*
 Copyright (c) 2011, Joachim Bengtsson
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 
 * Neither the name of the organization nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

// Copyright (c) 2010 Spotify AB
#import "SPMediaKeyTap.h"
#import "SPInvocationGrabbing.h" // https://gist.github.com/511181

@interface SPMediaKeyTap ()
-(BOOL)shouldInterceptMediaKeyEvents;
-(void)startWatchingAppSwitching;
-(void)stopWatchingAppSwitching;
-(void)eventTapThread;
@end
static SPMediaKeyTap *singleton = nil;

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);


// Inspired by http://gist.github.com/546311

@implementation SPMediaKeyTap

#pragma mark -
#pragma mark Setup and teardown
-(id)initWithDelegate:(id)delegate;
{
    _delegate = delegate;
    [self startWatchingAppSwitching];
    singleton = self;
    _mediaKeyAppList = [NSMutableArray new];
    return self;
}
-(void)dealloc;
{
    [self stopWatchingMediaKeys];
    [self stopWatchingAppSwitching];
    [_mediaKeyAppList release];
    [super dealloc];
}

-(void)startWatchingAppSwitching;
{
    // Listen to "app switched" event, so that we don't intercept media keys if we
    // weren't the last "media key listening" app to be active
    EventTypeSpec eventType = { kEventClassApplication, kEventAppFrontSwitched };
    OSStatus err = InstallApplicationEventHandler(NewEventHandlerUPP(appSwitched), 1, &eventType, self, &_app_switching_ref);
    assert(err == noErr);

    eventType.eventKind = kEventAppTerminated;
    err = InstallApplicationEventHandler(NewEventHandlerUPP(appTerminated), 1, &eventType, self, &_app_terminating_ref);
    assert(err == noErr);
}
-(void)stopWatchingAppSwitching;
{
    if(!_app_switching_ref) return;
    RemoveEventHandler(_app_switching_ref);
    _app_switching_ref = NULL;
}

-(void)startWatchingMediaKeys;{
    [self setShouldInterceptMediaKeyEvents:YES];

    // Add an event tap to intercept the system defined media key events
    _eventPort = CGEventTapCreate(kCGSessionEventTap,
                                  kCGHeadInsertEventTap,
                                  kCGEventTapOptionDefault,
                                  CGEventMaskBit(NX_SYSDEFINED),
                                  tapEventCallback,
                                  self);
    assert(_eventPort != NULL);

    _eventPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, _eventPort, 0);
    assert(_eventPortSource != NULL);

    // Let's do this in a separate thread so that a slow app doesn't lag the event tap
    [NSThread detachNewThreadSelector:@selector(eventTapThread) toTarget:self withObject:nil];
}
-(void)stopWatchingMediaKeys;
{
    // TODO<nevyn>: Shut down thread, remove event tap port and source
}

#pragma mark -
#pragma mark Accessors

+(BOOL)usesGlobalMediaKeyTap
{
    return YES;
#ifdef _DEBUG
    return NO;
#else
    // XXX(nevyn): MediaKey event tap doesn't work on 10.4, feel free to figure out why if you have the energy.
    return floor(NSAppKitVersionNumber) >= 949/*NSAppKitVersionNumber10_5*/;
#endif
}

+ (NSArray*)defaultMediaKeyUserBundleIdentifiers;
{
    return [NSArray arrayWithObjects:
        @"com.spotify.client",
        @"com.apple.iTunes",
        @"com.apple.QuickTimePlayerX",
        @"com.apple.quicktimeplayer",
        @"com.apple.iWork.Keynote",
        @"com.apple.iPhoto",
        @"org.videolan.vlc",
        @"com.apple.Aperture",
        @"com.plexsquared.Plex",
        @"com.soundcloud.desktop",
        @"com.macromedia.fireworks", // the tap messes up their mouse input
        nil
    ];
}


-(BOOL)shouldInterceptMediaKeyEvents;
{
    BOOL shouldIntercept = NO;
    @synchronized(self) {
        shouldIntercept = _shouldInterceptMediaKeyEvents;
    }
    return shouldIntercept;
}

-(void)pauseTapOnTapThread:(BOOL)yeahno;
{
    CGEventTapEnable(self->_eventPort, yeahno);
}
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
{
    BOOL oldSetting;
    @synchronized(self) {
        oldSetting = _shouldInterceptMediaKeyEvents;
        _shouldInterceptMediaKeyEvents = newSetting;
    }
    if(_tapThreadRL && oldSetting != newSetting) {
        id grab = [self grab];
        [grab pauseTapOnTapThread:newSetting];
        NSTimer *timer = [NSTimer timerWithTimeInterval:0 invocation:[grab invocation] repeats:NO];
        CFRunLoopAddTimer(_tapThreadRL, (CFRunLoopTimerRef)timer, kCFRunLoopCommonModes);
    }
}

#pragma mark 
#pragma mark -
#pragma mark Event tap callbacks

// Note: method called on background thread

static CGEventRef tapEventCallback2(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    SPMediaKeyTap *self = refcon;

    if(type == kCGEventTapDisabledByTimeout) {
        NSLog(@"Media key event tap was disabled by timeout");
        CGEventTapEnable(self->_eventPort, TRUE);
        return event;
    } else if(type == kCGEventTapDisabledByUserInput) {
        // Was disabled manually by -[pauseTapOnTapThread]
        return event;
    }
    NSEvent *nsEvent = nil;
    @try {
        nsEvent = [NSEvent eventWithCGEvent:event];
    }
    @catch (NSException * e) {
        NSLog(@"Strange CGEventType: %d: %@", type, e);
        assert(0);
        return event;
    }

    if (type != NX_SYSDEFINED || [nsEvent subtype] != SPSystemDefinedEventMediaKeys)
        return event;

    int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);
    if (keyCode != NX_KEYTYPE_PLAY && keyCode != NX_KEYTYPE_FAST && keyCode != NX_KEYTYPE_REWIND)
        return event;

    if (![self shouldInterceptMediaKeyEvents])
        return event;

    [nsEvent retain]; // matched in handleAndReleaseMediaKeyEvent:
    [self performSelectorOnMainThread:@selector(handleAndReleaseMediaKeyEvent:) withObject:nsEvent waitUntilDone:NO];

    return NULL;
}

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    CGEventRef ret = tapEventCallback2(proxy, type, event, refcon);
    [pool drain];
    return ret;
}


// event will have been retained in the other thread
-(void)handleAndReleaseMediaKeyEvent:(NSEvent *)event {
    [event autorelease];

    [_delegate mediaKeyTap:self receivedMediaKeyEvent:event];
}


-(void)eventTapThread;
{
    _tapThreadRL = CFRunLoopGetCurrent();
    CFRunLoopAddSource(_tapThreadRL, _eventPortSource, kCFRunLoopCommonModes);
    CFRunLoopRun();
}

#pragma mark Task switching callbacks

NSString *kMediaKeyUsingBundleIdentifiersDefaultsKey = @"SPApplicationsNeedingMediaKeys";


-(void)mediaKeyAppListChanged;
{
    if([_mediaKeyAppList count] == 0) return;

    /*NSLog(@"--");
    int i = 0;
    for (NSValue *psnv in _mediaKeyAppList) {
        ProcessSerialNumber psn; [psnv getValue:&psn];
        NSDictionary *processInfo = [(id)ProcessInformationCopyDictionary(
            &psn,
            kProcessDictionaryIncludeAllInformationMask
        ) autorelease];
        NSString *bundleIdentifier = [processInfo objectForKey:(id)kCFBundleIdentifierKey];
        NSLog(@"%d: %@", i++, bundleIdentifier);
    }*/

    ProcessSerialNumber mySerial, topSerial;
    GetCurrentProcess(&mySerial);
    [[_mediaKeyAppList objectAtIndex:0] getValue:&topSerial];

    Boolean same;
    OSErr err = SameProcess(&mySerial, &topSerial, &same);
    [self setShouldInterceptMediaKeyEvents:(err == noErr && same)];

}
-(void)appIsNowFrontmost:(ProcessSerialNumber)psn;
{
    NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];

    NSDictionary *processInfo = [(id)ProcessInformationCopyDictionary(
        &psn,
        kProcessDictionaryIncludeAllInformationMask
    ) autorelease];
    NSString *bundleIdentifier = [processInfo objectForKey:(id)kCFBundleIdentifierKey];

    NSArray *whitelistIdentifiers = [[NSUserDefaults standardUserDefaults] arrayForKey:kMediaKeyUsingBundleIdentifiersDefaultsKey];
    if(![whitelistIdentifiers containsObject:bundleIdentifier]) return;

    [_mediaKeyAppList removeObject:psnv];
    [_mediaKeyAppList insertObject:psnv atIndex:0];
    [self mediaKeyAppListChanged];
}
-(void)appTerminated:(ProcessSerialNumber)psn;
{
    NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];
    [_mediaKeyAppList removeObject:psnv];
    [self mediaKeyAppListChanged];
}

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
    SPMediaKeyTap *self = (id)userData;

    ProcessSerialNumber newSerial;
    GetFrontProcess(&newSerial);

    [self appIsNowFrontmost:newSerial];

    return CallNextEventHandler(nextHandler, evt);
}

static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
    SPMediaKeyTap *self = (id)userData;

    ProcessSerialNumber deadPSN;

    GetEventParameter(
        evt,
        kEventParamProcessID,
        typeProcessSerialNumber,
        NULL,
        sizeof(deadPSN),
        NULL,
        &deadPSN
    );


    [self appTerminated:deadPSN];
    return CallNextEventHandler(nextHandler, evt);
}

@end
