// AFSecurityPolicy.m
// Copyright (c) 2011–2015 Alamofire Software Foundation (http://alamofire.org/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFSecurityPolicy.h"

#import <AssertMacros.h>

#if !TARGET_OS_IOS && !TARGET_OS_WATCH
static NSData * AFSecKeyGetData(SecKeyRef key) {
    CFDataRef data = NULL;

    __Require_noErr_Quiet(SecItemExport(key, kSecFormatUnknown, kSecItemPemArmour, NULL, &data), _out);

    return (__bridge_transfer NSData *)data;

_out:
    if (data) {
        CFRelease(data);
    }

    return nil;
}
#endif

// 判断两个 secrity key 是否相等
static BOOL AFSecKeyIsEqualToKey(SecKeyRef key1, SecKeyRef key2) {
#if TARGET_OS_IOS || TARGET_OS_WATCH
    return [(__bridge id)key1 isEqual:(__bridge id)key2];
#else
    return [AFSecKeyGetData(key1) isEqual:AFSecKeyGetData(key2)];
#endif
}

/**
 *  从证书中获取 publickey
 *
 *  @param certificate 需要获取的证书
 *
 *  @return 返回 信任信息中的 public key. type: SecTrustRef
 */
static id AFPublicKeyForCertificate(NSData *certificate) {
    id allowedPublicKey = nil;  //(__bridge SecKeyRef)
    SecCertificateRef allowedCertificate;//抽象的 CFType 的 X.509 certificate对象
    SecCertificateRef allowedCertificates[1];
    CFArrayRef tempCertificates = nil;
    SecPolicyRef policy = nil;// X.509 policy对象, 内部有 X.509 policy的信息
    SecTrustRef allowedTrust = nil;// 信任信息
    SecTrustResultType result;

    //取证书SecCertificateRef -> 生成证书数组 -> 生成SecTrustRef -> 从SecTrustRef取PublicKey
    //通过 certificate data(DER 格式的)创建certificate对象
    allowedCertificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificate);
    __Require_Quiet(allowedCertificate != NULL, _out);

    //将证书放到证书数组
    allowedCertificates[0] = allowedCertificate;
    //创建一个 temp array CFType
    tempCertificates = CFArrayCreate(NULL, (const void **)allowedCertificates, 1, NULL);
    
    //生成 X.509 default policy
    policy = SecPolicyCreateBasicX509();
    //根据 证书 和 认证策略 创建一个 信任管理的对象
    __Require_noErr_Quiet(SecTrustCreateWithCertificates(tempCertificates, policy, &allowedTrust), _out);
    // 鉴定 信任信息对象 的内容, 返回信任结果(在 allowedTrust 中, 有可能阻塞调用线程)
//     使用系统默认验证方式验证Trust Object。SecTrustEvaluate会根据Trust Object的验证策略，一级一级往上，验证证书链上每一级数字签名的有效性（上一部分有讲解），从而评估证书的有效性。
    __Require_noErr_Quiet(SecTrustEvaluate(allowedTrust, &result), _out);

    //在信任信息对象被鉴定以后,调用该方法获取 SecTrustRef 信任信息的 public key
    allowedPublicKey = (__bridge_transfer id)SecTrustCopyPublicKey(allowedTrust);

_out:
    if (allowedTrust) {
        CFRelease(allowedTrust);
    }

    if (policy) {
        CFRelease(policy);
    }

    if (tempCertificates) {
        CFRelease(tempCertificates);
    }

    if (allowedCertificate) {
        CFRelease(allowedCertificate);
    }

    return allowedPublicKey;
}


/**
 *  传入信任信息 进行服务器认证
 *
 *  @param serverTrust 服务端的信任信息
 *
 *  @return 服务器认证结果 yes 合法  no 不合法
 */
static BOOL AFServerTrustIsValid(SecTrustRef serverTrust) {
    BOOL isValid = NO;
    SecTrustResultType result;
    //鉴定 信任信息的内容,坚定结果在 result
//     使用系统默认验证方式验证Trust Object。SecTrustEvaluate会根据Trust Object的验证策略，一级一级往上，验证证书链上每一级数字签名的有效性（上一部分有讲解），从而评估证书的有效性。
    __Require_noErr_Quiet(SecTrustEvaluate(serverTrust, &result), _out);

    //kSecTrustResultUnspecified:证书通过验证，但用户没有设置这些证书是否被信任
    //kSecTrustResultProceed:证书通过验证，用户有操作设置了证书被信任，例如在弹出的是否信任的alert框中选择always trust
    isValid = (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);
    //3)验证成功，生成NSURLCredential凭证cred，告知challenge的sender使用这个凭证来继续连接


_out:
    return isValid;
}

//取出服务端返回的证书链中的所有的证书
static NSArray * AFCertificateTrustChainForServerTrust(SecTrustRef serverTrust) {
    //获取鉴定证书链中 certificates 的 count
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];

    //证书链
    for (CFIndex i = 0; i < certificateCount; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        //传入 certificate object 返回 DER格式的 certificate data,并放入到 array
        [trustChain addObject:(__bridge_transfer NSData *)SecCertificateCopyData(certificate)];
    }

    return [NSArray arrayWithArray:trustChain];
}

//取出服务端返回证书链里所有的public key
static NSArray * AFPublicKeyTrustChainForServerTrust(SecTrustRef serverTrust) {
    //证书策略
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    //服务端返回的证书链的证书数
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];
    for (CFIndex i = 0; i < certificateCount; i++) {
        //从证书链中取出一个证书, 先进行 policy evaluate ,然后取出 public key,再放入 array,并返回
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);

        SecCertificateRef someCertificates[] = {certificate};
        CFArrayRef certificates = CFArrayCreate(NULL, (const void **)someCertificates, 1, NULL);

        SecTrustRef trust;
        __Require_noErr_Quiet(SecTrustCreateWithCertificates(certificates, policy, &trust), _out);

        SecTrustResultType result;
//         使用系统默认验证方式验证Trust Object。SecTrustEvaluate会根据Trust Object的验证策略，一级一级往上，验证证书链上每一级数字签名的有效性（上一部分有讲解），从而评估证书的有效性。
        __Require_noErr_Quiet(SecTrustEvaluate(trust, &result), _out);

        [trustChain addObject:(__bridge_transfer id)SecTrustCopyPublicKey(trust)];

    _out:
        if (trust) {
            CFRelease(trust);
        }

        if (certificates) {
            CFRelease(certificates);
        }

        continue;
    }
    CFRelease(policy);

    return [NSArray arrayWithArray:trustChain];
}

#pragma mark -

@interface AFSecurityPolicy()
@property (readwrite, nonatomic, assign) AFSSLPinningMode SSLPinningMode;
@property (readwrite, nonatomic, strong) NSArray *pinnedPublicKeys;
@end

@implementation AFSecurityPolicy

// 如果将自己的证书放到自己的 xxxxx.bundle 中,可以使用以下代码
+ (NSArray *)defaultPinnedCertificates2 {
    static NSArray *_defaultPinnedCertificates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSArray *paths = [bundle pathsForResourcesOfType:@"bundle" inDirectory:@"."];
        NSBundle *customBundle = nil;
        if ([paths count] > 0){
            for (int i = 0; i < [paths count]; i ++) {
                NSString *string = [paths objectAtIndex:i];
                if ([string hasSuffix:@"xxxxx.bundle"]) {
                    customBundle = [NSBundle bundleWithPath:string];
                    break;
                }
            }
            if (nil != customBundle) {
                paths = [customBundle pathsForResourcesOfType:@"cer" inDirectory:@"."];
            }
        }
        
        NSMutableArray *certificates = [NSMutableArray arrayWithCapacity:[paths count]];
        for (NSString *path in paths) {
            NSData *certificateData = [NSData dataWithContentsOfFile:path];
            [certificates addObject:certificateData];
        }
        _defaultPinnedCertificates = [[NSArray alloc] initWithArray:certificates];
    });
    
    return _defaultPinnedCertificates;
}

//获取 pin mode的证书的 data 的数组
+ (NSArray *)defaultPinnedCertificates {
    //默认证书列表，遍历根目录下所有.cer文件 --  如果证书列表不在根目录的 bundle 中,需要手动设定地址
    static NSArray *_defaultPinnedCertificates = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSArray *paths = [bundle pathsForResourcesOfType:@"cer" inDirectory:@"."];

        NSMutableArray *certificates = [NSMutableArray arrayWithCapacity:[paths count]];
        for (NSString *path in paths) {
            NSData *certificateData = [NSData dataWithContentsOfFile:path];
            [certificates addObject:certificateData];
        }

        _defaultPinnedCertificates = [[NSArray alloc] initWithArray:certificates];
    });

    return _defaultPinnedCertificates;
}

+ (instancetype)defaultPolicy {
    AFSecurityPolicy *securityPolicy = [[self alloc] init];
    // 默认的安全策略是 AFSSLPinningModeNone, 此时不需要设置_pinnedCertificates 属性
    securityPolicy.SSLPinningMode = AFSSLPinningModeNone;

    return securityPolicy;
}

+ (instancetype)policyWithPinningMode:(AFSSLPinningMode)pinningMode {
    AFSecurityPolicy *securityPolicy = [[self alloc] init];
    securityPolicy.SSLPinningMode = pinningMode;

    [securityPolicy setPinnedCertificates:[self defaultPinnedCertificates]];

    return securityPolicy;
}

- (id)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    //默认是需要 验证 domain 名称的
    self.validatesDomainName = YES;

    return self;
}
//The certificates used to evaluate server trust according to the SSL pinning mode. By default, this property is set to any (`.cer`) certificates included in the app bundle. Note that if you create an array with duplicate certificates, the duplicate certificates will be removed. Note that if pinning is enabled, `evaluateServerTrust:forDomain:` will return true if any pinned certificate matches.
- (void)setPinnedCertificates:(NSArray *)pinnedCertificates {
    _pinnedCertificates = [[NSOrderedSet orderedSetWithArray:pinnedCertificates] array];

    if (self.pinnedCertificates) {
        NSMutableArray *mutablePinnedPublicKeys = [NSMutableArray arrayWithCapacity:[self.pinnedCertificates count]];
        for (NSData *certificate in self.pinnedCertificates) {
            //从证书中获取 public key
            id publicKey = AFPublicKeyForCertificate(certificate);
            if (!publicKey) {
                continue;
            }
            [mutablePinnedPublicKeys addObject:publicKey];
        }
        //设置进入 pinned Public key
        self.pinnedPublicKeys = [NSArray arrayWithArray:mutablePinnedPublicKeys];
    } else {
        self.pinnedPublicKeys = nil;
    }
}

#pragma mark -
/**
 是否信任 server. 当远程 server 要 authentication challenge 时需要调用这个方法
 
 @param serverTrust The X.509 certificate trust of the server.
 
 @return 是否信任 server
 
 @warning This method has been deprecated in favor of `-evaluateServerTrust:forDomain:`.
 */
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust {
    return [self evaluateServerTrust:serverTrust forDomain:nil];
}

/**
 
 是否信任指定的 server. 当 server 需要 authentication challenge 时候调用
 @param serverTrust The X.509 certificate trust of the server.
 @param domain The domain of serverTrust. If `nil`, the domain will not be validated.
 
 @return Whether or not to trust the server.
 */
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust
                  forDomain:(NSString *)domain
{
    if (domain && self.allowInvalidCertificates && self.validatesDomainName && (self.SSLPinningMode == AFSSLPinningModeNone || [self.pinnedCertificates count] == 0)) {
        // https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/NetworkingTopics/Articles/OverridingSSLChainValidationCorrectly.html
        //  According to the docs, you should only trust your provided certs for evaluation.
        //  Pinned certificates are added to the trust. Without pinned certificates,
        //  there is nothing to evaluate against.
        //
        //  From Apple Docs:
        //          "Do not implicitly trust self-signed certificates as anchors (kSecTrustOptionImplicitAnchors).
        //           Instead, add your own (self-signed) CA certificate to the list of trusted anchors."
        NSLog(@"In order to validate a domain name for self signed certificates, you MUST use pinning.");
        return NO;
    }

    NSMutableArray *policies = [NSMutableArray array];
    if (self.validatesDomainName) {
        //需要 认证域名
        [policies addObject:(__bridge_transfer id)SecPolicyCreateSSL(true, (__bridge CFStringRef)domain)];
    } else {
        // 只需要证书是 X509格式就 ok
        [policies addObject:(__bridge_transfer id)SecPolicyCreateBasicX509()];
    }

    //设置鉴定过程中的规则策略
    SecTrustSetPolicies(serverTrust, (__bridge CFArrayRef)policies);

    //向系统内置的根证书验证服务端返回的证书是否合法
    //若使用自签名证书，这里的验证是会不合法的，需要设allowInvalidCertificates = YES
    if (self.SSLPinningMode == AFSSLPinningModeNone) {
        return self.allowInvalidCertificates || AFServerTrustIsValid(serverTrust);
    } else if (!AFServerTrustIsValid(serverTrust) && !self.allowInvalidCertificates) {
        return NO;
    }

    // 取出服务端返回的证书
    NSArray *serverCertificates = AFCertificateTrustChainForServerTrust(serverTrust);
    switch (self.SSLPinningMode) {
        case AFSSLPinningModeNone:
            //两种情况走到这里，
            //一是通过系统证书验证，返回认证成功
            //二是没通过验证，但allowInvalidCertificates = YES，也就是说完全不认证直接返回认证成功
        default:
            return NO;
            //验证整个证书
        case AFSSLPinningModeCertificate: {
            //创建证书数组里面的内容是SecCertificateRef object
            NSMutableArray *pinnedCertificates = [NSMutableArray array];
            for (NSData *certificateData in self.pinnedCertificates) {
                [pinnedCertificates addObject:(__bridge_transfer id)SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData)];
            }
            //通过本地证书array 中来验证服务端返回的证书的 **有效性**
            SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)pinnedCertificates);

            if (!AFServerTrustIsValid(serverTrust)) {
                return NO;
            }

            NSUInteger trustedCertificateCount = 0;
            //整个证书链都跟本地的证书匹配才给过
            for (NSData *trustChainCertificate in serverCertificates) {
                if ([self.pinnedCertificates containsObject:trustChainCertificate]) {
                    trustedCertificateCount++;
                }
            }
            return trustedCertificateCount > 0;
        }
        //只验证证书的public key
        case AFSSLPinningModePublicKey: {
            NSUInteger trustedPublicKeyCount = 0;
            //从服务器中的 serverTrust 取出所有的 public keys
            NSArray *publicKeys = AFPublicKeyTrustChainForServerTrust(serverTrust);

            //如果不用验证整个证书链，取第一个也就是真正会使用的那个证书验证就行
            for (id trustChainPublicKey in publicKeys) {
                //在本地证书里搜索相等的public key，记录找到个数
                for (id pinnedPublicKey in self.pinnedPublicKeys) {
                    //判断两个 key 是否相等
                    if (AFSecKeyIsEqualToKey((__bridge SecKeyRef)trustChainPublicKey, (__bridge SecKeyRef)pinnedPublicKey)) {
                        trustedPublicKeyCount += 1;
                    }
                }
            }
            //验证整个证书链的情况：每个public key都在本地找到算验证通过
            //验证单个证书的情况：找到一个算验证通过
            return trustedPublicKeyCount > 0;
        }
    }
    return NO;
}

#pragma mark - NSKeyValueObserving

+ (NSSet *)keyPathsForValuesAffectingPinnedPublicKeys {
    return [NSSet setWithObject:@"pinnedCertificates"];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)decoder {

    self = [self init];
    if (!self) {
        return nil;
    }

    self.SSLPinningMode = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(SSLPinningMode))] unsignedIntegerValue];
    self.allowInvalidCertificates = [decoder decodeBoolForKey:NSStringFromSelector(@selector(allowInvalidCertificates))];
    self.validatesDomainName = [decoder decodeBoolForKey:NSStringFromSelector(@selector(validatesDomainName))];
    self.pinnedCertificates = [decoder decodeObjectOfClass:[NSArray class] forKey:NSStringFromSelector(@selector(pinnedCertificates))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:[NSNumber numberWithUnsignedInteger:self.SSLPinningMode] forKey:NSStringFromSelector(@selector(SSLPinningMode))];
    [coder encodeBool:self.allowInvalidCertificates forKey:NSStringFromSelector(@selector(allowInvalidCertificates))];
    [coder encodeBool:self.validatesDomainName forKey:NSStringFromSelector(@selector(validatesDomainName))];
    [coder encodeObject:self.pinnedCertificates forKey:NSStringFromSelector(@selector(pinnedCertificates))];
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone {
    AFSecurityPolicy *securityPolicy = [[[self class] allocWithZone:zone] init];
    securityPolicy.SSLPinningMode = self.SSLPinningMode;
    securityPolicy.allowInvalidCertificates = self.allowInvalidCertificates;
    securityPolicy.validatesDomainName = self.validatesDomainName;
    securityPolicy.pinnedCertificates = [self.pinnedCertificates copyWithZone:zone];

    return securityPolicy;
}

@end
