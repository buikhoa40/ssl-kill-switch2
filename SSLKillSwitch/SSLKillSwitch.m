//
//  SSLKillSwitch.m
//  SSLKillSwitch
//
//  Created by Alban Diquet on 7/10/15.
//  Copyright (c) 2015 Alban Diquet. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Security/SecureTransport.h>

#if SUBSTRATE_BUILD
#import "substrate.h"
#else
#import "fishhook.h"
#import <dlfcn.h>
#endif


#define PREFERENCE_FILE @"/private/var/mobile/Library/Preferences/com.nablac0d3.SSLKillSwitchSettings.plist"
#define PREFERENCE_KEY @"shouldDisableCertificateValidation"

#pragma mark Utility Functions

static void SSKLog(NSString *format, ...)
{
    NSString *newFormat = [[NSString alloc] initWithFormat:@"=== SSL Kill Switch 2: %@", format];
    va_list args;
    va_start(args, format);
    NSLogv(newFormat, args);
    va_end(args);
}


#if SUBSTRATE_BUILD
// Utility function to read the Tweak's preferences
static BOOL shouldHookFromPreference(NSString *preferenceSetting)
{
    BOOL shouldHook = NO;
    NSMutableDictionary* plist = [[NSMutableDictionary alloc] initWithContentsOfFile:PREFERENCE_FILE];
    
    if (!plist)
    {
        SSKLog(@"Preference file not found.");
    }
    else
    {
        shouldHook = [[plist objectForKey:preferenceSetting] boolValue];
        SSKLog(@"Preference set to %d.", shouldHook);
    }
    return shouldHook;
}
#endif


#pragma mark SSLSetSessionOption Hook

static OSStatus (*original_SSLSetSessionOption)(SSLContextRef context,
                                                SSLSessionOption option,
                                                Boolean value);

static OSStatus replaced_SSLSetSessionOption(SSLContextRef context,
                                             SSLSessionOption option,
                                             Boolean value)
{
    // Remove the ability to modify the value of the kSSLSessionOptionBreakOnServerAuth option
    if (option == kSSLSessionOptionBreakOnServerAuth)
    {
        return noErr;
    }
    return original_SSLSetSessionOption(context, option, value);
}


#pragma mark SSLCreateContext Hook

// Declare the TrustKit selector we need here
@protocol TrustKitMethod <NSObject>
+ (void) resetConfiguration;
@end

static SSLContextRef (*original_SSLCreateContext)(CFAllocatorRef alloc,
                                                  SSLProtocolSide protocolSide,
                                                  SSLConnectionType connectionType);

static SSLContextRef replaced_SSLCreateContext(CFAllocatorRef alloc,
                                               SSLProtocolSide protocolSide,
                                               SSLConnectionType connectionType)
{
    SSLContextRef sslContext = original_SSLCreateContext(alloc, protocolSide, connectionType);
    
    // Disable TrustKit if it is present
    Class TrustKit = NSClassFromString(@"TrustKit");
    if (TrustKit != nil)
    {
        [TrustKit performSelector:@selector(resetConfiguration)];
    }
    
    // Immediately set the kSSLSessionOptionBreakOnServerAuth option in order to disable cert validation
    original_SSLSetSessionOption(sslContext, kSSLSessionOptionBreakOnServerAuth, true);
    return sslContext;
}


#pragma mark SSLHandshake Hook

static OSStatus (*original_SSLHandshake)(SSLContextRef context);

static OSStatus replaced_SSLHandshake(SSLContextRef context)
{
    OSStatus result = original_SSLHandshake(context);
    
    // Hijack the flow when breaking on server authentication
    if (result == errSSLServerAuthCompleted)
    {
        // Do not check the cert and call SSLHandshake() again
        return original_SSLHandshake(context);
    }
    
    return result;
}


#pragma mark CocoaSPDY hook
#if SUBSTRATE_BUILD

static void (*oldSetTLSTrustEvaluator)(id self, SEL _cmd, id evaluator);

static void newSetTLSTrustEvaluator(id self, SEL _cmd, id evaluator)
{
    // Set a nil evaluator to disable SSL validation
    oldSetTLSTrustEvaluator(self, _cmd, nil);
}

static void (*oldSetprotocolClasses)(id self, SEL _cmd, NSArray <Class> *protocolClasses);

static void newSetprotocolClasses(id self, SEL _cmd, NSArray <Class> *protocolClasses)
{
    // Do not register protocol classes which is how CocoaSPDY works
    // This should force the App to downgrade from SPDY to HTTPS
}

static void (*oldRegisterOrigin)(id self, SEL _cmd, NSString *origin);

static void newRegisterOrigin(id self, SEL _cmd, NSString *origin)
{
    // Do not register protocol classes which is how CocoaSPDY works
    // This should force the App to downgrade from SPDY to HTTPS
}


#pragma mark RCTSRWebSocket hook

static void (*oldSetRCTSR_SSLPinnedCertificates)(id self, SEL _cmd, id certs);

static void newSetRCTSR_SSLPinnedCertificates(id self, SEL _cmd, id certs)
{
    // Do nothing to disable the ability to enable pinning
    SSKLog(@"Called RCTSRWebSocket");
    return;
}


#pragma mark FBMQTTNativeClient hook

static BOOL (*old_verifyCertificate)(id self, SEL _cmd, SecTrustRef trust, id arg2);

static BOOL new_verifyCertificate(id self, SEL _cmd, SecTrustRef trust, id arg2)
{
    // Yes of course, this certificate is trusted
    SSKLog(@"Called FBMQTTNativeClient");
    return YES;
}


#pragma mark FBSSLPinningVerifier hook

static BOOL (*oldCheckPinning)(id self, SEL _cmd, id args1);

static BOOL newCheckPinning(id self, SEL _cmd, id args1)
{
    // Yes of course, this certificate is trusted
    SSKLog(@"Called FBSSLPinningVerifier");
    return YES;
}

static id (*oldSharedVerifier)(id self, SEL _cmd);

static id newSharedVerifier(id self, SEL _cmd)
{
    // Yes of course, this certificate is trusted
    SSKLog(@"Called FBSSLPinningVerifier sharedVerifier");
    return oldSharedVerifier(self, _cmd);
}

static id (*oldSharedStore)(id self, SEL _cmd);

static id newSharedStore(id self, SEL _cmd)
{
    // Yes of course, this certificate is trusted
    SSKLog(@"Called OAUTH2 sharedStore");
    return oldSharedStore(self, _cmd);
}

static id (*oldSendQuery)(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4, id arg5);

static id newSendQuery(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4, id arg5)
{
    // Yes of course, this certificate is trusted
    SSKLog(@"Called SEND QUERY");
    return oldSendQuery(self, _cmd, arg1, arg2, arg3, arg4, arg5);
}



#endif


#pragma mark Dylib Constructor

__attribute__((constructor)) static void init(int argc, const char **argv)
{
#if SUBSTRATE_BUILD
    // Should we enable the hook ?
    if (shouldHookFromPreference(PREFERENCE_KEY))
    {
        // Substrate-based hooking; only hook if the preference file says so
        SSKLog(@"Subtrate hook enabled.");
        
        // SecureTransport hooks
        MSHookFunction((void *) SSLHandshake,(void *)  replaced_SSLHandshake, (void **) &original_SSLHandshake);
        MSHookFunction((void *) SSLSetSessionOption,(void *)  replaced_SSLSetSessionOption, (void **) &original_SSLSetSessionOption);
        MSHookFunction((void *) SSLCreateContext,(void *)  replaced_SSLCreateContext, (void **) &original_SSLCreateContext);
        
        // CocoaSPDY hooks (for Twitter) - https://github.com/twitter/CocoaSPDY
        // TODO: Enable these hooks for the fishhook-based hooking so it works on OS X too
        Class spdyProtocolClass = NSClassFromString(@"SPDYProtocol");
        if (spdyProtocolClass)
        {
            // Disable trust evaluation
            MSHookMessageEx(object_getClass(spdyProtocolClass), NSSelectorFromString(@"setTLSTrustEvaluator:"), (IMP) &newSetTLSTrustEvaluator, (IMP *)&oldSetTLSTrustEvaluator);
            
            // CocoaSPDY works by getting registered as a NSURLProtocol; block that so the Apps switches back to HTTP as SPDY is tricky to proxy
            Class spdyUrlConnectionProtocolClass = NSClassFromString(@"SPDYURLConnectionProtocol");
            MSHookMessageEx(object_getClass(spdyUrlConnectionProtocolClass), NSSelectorFromString(@"registerOrigin:"), (IMP) &newRegisterOrigin, (IMP *)&oldRegisterOrigin);
            
            MSHookMessageEx(NSClassFromString(@"NSURLSessionConfiguration"), NSSelectorFromString(@"setprotocolClasses:"), (IMP) &newSetprotocolClasses, (IMP *)&oldSetprotocolClasses);
        }
        
        
        // RCTSRWebSocket hooks (for Facebook) - https://github.com/facebook/react-native/blob/master/Libraries/WebSocket/RCTSRWebSocket.m
        SEL webSocketPinningSelector = NSSelectorFromString(@"setRCTSR_SSLPinnedCertificates:");
        if ([NSMutableURLRequest instancesRespondToSelector:webSocketPinningSelector])
        {
            SSKLog(@"Enabling WebSocket hooks");
            MSHookMessageEx([NSMutableURLRequest class], webSocketPinningSelector, (IMP) &newSetRCTSR_SSLPinnedCertificates, (IMP *)&oldSetRCTSR_SSLPinnedCertificates);
        }
        

        // FBMQTTNativeClient hooks (for Facebook)
        Class FBMQTTNativeClientClass = NSClassFromString(@"FBMQTTNativeClient");
        if (FBMQTTNativeClientClass)
        {
            SSKLog(@"Enabling FBMQTTNativeClient hooks");
            MSHookMessageEx(FBMQTTNativeClientClass, NSSelectorFromString(@"_verifyCertificate:errorMessage:"), (IMP) &new_verifyCertificate, (IMP *)&old_verifyCertificate);
        }
        
        // FBSSLPinningVerifier hooks (for Facebook)
        Class FBSSLPinningVerifierClass = NSClassFromString(@"FBSSLPinningVerifier");
        if (FBSSLPinningVerifierClass)
        {
            SSKLog(@"Enabling FBSSLPinningVerifier hooks");
            MSHookMessageEx(FBSSLPinningVerifierClass, NSSelectorFromString(@"checkPinning:"), (IMP) &newCheckPinning, (IMP *)&oldCheckPinning);
            MSHookMessageEx(object_getClass(FBSSLPinningVerifierClass), NSSelectorFromString(@"sharedVerifier"), (IMP) &newSharedVerifier, (IMP *)&oldSharedVerifier);
        }
        
        Class FBDeviceBasedLoginAccountStoreClass = NSClassFromString(@"FBDeviceBasedLoginAccountStore");
        if (FBDeviceBasedLoginAccountStoreClass)
        {
            SSKLog(@"Enabling FBDeviceBasedLoginAccountStore hooks");
            MSHookMessageEx(object_getClass(FBDeviceBasedLoginAccountStoreClass), NSSelectorFromString(@"sharedStore"), (IMP) &newSharedStore, (IMP *)&oldSharedStore);
        }
        
        Class FBGraphQLServiceClass = NSClassFromString(@"FBGraphQLService");
        if (FBGraphQLServiceClass)
        {
            SSKLog(@"Enabling FBGraphQLService hooks");
            MSHookMessageEx(FBGraphQLServiceClass, NSSelectorFromString(@"sendQuery:callbackQueue:successCallback:failureCallback:configurationCallback:"), (IMP) &newSendQuery, (IMP *)&oldSendQuery);
        }
        
        
        
    }
    else
    {
        SSKLog(@"Subtrate hook disabled.");
    }
    
#else
    // Fishhook-based hooking, for OS X builds; always hook
    SSKLog(@"Fishhook hook enabled.");
    original_SSLHandshake = dlsym(RTLD_DEFAULT, "SSLHandshake");
    if ((rebind_symbols((struct rebinding[1]){{(char *)"SSLHandshake", (void *)replaced_SSLHandshake}}, 1) < 0))
    {
        SSKLog(@"Hooking failed.");
    }
    
    original_SSLSetSessionOption = dlsym(RTLD_DEFAULT, "SSLSetSessionOption");
    if ((rebind_symbols((struct rebinding[1]){{(char *)"SSLSetSessionOption", (void *)replaced_SSLSetSessionOption}}, 1) < 0))
    {
        SSKLog(@"Hooking failed.");
    }
    
    original_SSLCreateContext = dlsym(RTLD_DEFAULT, "SSLCreateContext");
    if ((rebind_symbols((struct rebinding[1]){{(char *)"SSLCreateContext", (void *)replaced_SSLCreateContext}}, 1) < 0))
    {
        SSKLog(@"Hooking failed.");
    }
#endif
}

