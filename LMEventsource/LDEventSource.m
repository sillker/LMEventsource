//
//  LDEventSource.m
//  LDEventSource
//
//  Created by Neil on 25/07/2013.
//  Copyright (c) 2013 Neil Cowburn. All rights reserved.
//

#import "LDEventSource.h"
#import "LDEventParser.h"
#import "LDEventStringAccumulator.h"
#import "NSString+LDEventSource.h"

static NSTimeInterval const ES_RETRY_INTERVAL = 1.0;
static NSTimeInterval const ES_DEFAULT_TIMEOUT = 300.0;
static NSTimeInterval const ES_MAX_RECONNECT_TIME = 3600.0;

NSString *const LDEventSourceErrorDomain = @"LDEventSourceErrorDomain";

static NSInteger const HTTPStatusCodeUnauthorized = 401;

@interface LDEventSource () <NSURLSessionDataDelegate> {
    BOOL wasClosed;
    dispatch_queue_t messageQueue;
    dispatch_queue_t connectionQueue;
}

@property (nonatomic, strong) NSURL *eventURL;
@property (nonatomic, strong) NSURLSessionDataTask *eventSourceTask;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary *listeners;
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
@property (nonatomic, assign) NSTimeInterval retryInterval;
@property (nonatomic, assign) NSInteger retryAttempt;
@property (nonatomic, strong) NSDictionary <NSString *, NSString *> *httpRequestHeaders;
@property (nonatomic, strong) NSString *connectMethod;
@property (nonatomic, strong) NSData *connectBody;
@property (nonatomic, strong) id lastEventID;
@property (nonatomic, strong) LDEventStringAccumulator *eventStringAccumulator;

@property (nonatomic, copy) NSString *receiveTempString;

- (void)open;
- (void)_dispatchEvent:(LDEvent *)e;

@end

@implementation LDEventSource

+ (instancetype)eventSourceWithURL:(NSURL *)URL httpHeaders:(NSDictionary<NSString*, NSString *>*) headers
{
    return [[LDEventSource alloc] initWithURL:URL httpHeaders:headers];
}

+ (instancetype)eventSourceWithURL:(NSURL *)URL httpHeaders:(NSDictionary<NSString*, NSString *>*)headers connectMethod:(NSString*)connectMethod connectBody:(NSData*)connectBody
{
    return [[LDEventSource alloc] initWithURL:URL httpHeaders:headers timeoutInterval:ES_DEFAULT_TIMEOUT connectMethod:connectMethod connectBody:connectBody];
}

+ (instancetype)eventSourceWithURL:(NSURL *)URL httpHeaders:(NSDictionary<NSString*, NSString *>*)headers timeoutInterval:(NSTimeInterval)timeoutInterval connectMethod:(NSString*)connectMethod connectBody:(NSData*)connectBody
{
    return [[LDEventSource alloc] initWithURL:URL httpHeaders:headers timeoutInterval:timeoutInterval connectMethod:connectMethod connectBody:connectBody];
}

- (instancetype)initWithURL:(NSURL *)URL httpHeaders:(NSDictionary<NSString*, NSString *>*) headers
{
    return [self initWithURL:URL httpHeaders:headers timeoutInterval:ES_DEFAULT_TIMEOUT connectMethod:@"GET" connectBody:nil];
}

- (instancetype)initWithURL:(NSURL *)URL httpHeaders:(NSDictionary<NSString*, NSString *>*) headers connectMethod:(NSString*)connectMethod connectBody:(NSData*)connectBody
{
    return [self initWithURL:URL httpHeaders:headers timeoutInterval:ES_DEFAULT_TIMEOUT connectMethod:connectMethod connectBody:connectBody];
}

- (instancetype)initWithURL:(NSURL *)URL
                httpHeaders:(NSDictionary<NSString*, NSString *>*)headers
            timeoutInterval:(NSTimeInterval)timeoutInterval
              connectMethod:(NSString*)connectMethod
                connectBody:(NSData*)connectBody {
    if (!(self = [super init])) {
        return nil;
    }

    self.listeners = [NSMutableDictionary dictionary];
    self.eventURL = URL;
    self.timeoutInterval = timeoutInterval;
    self.retryInterval = ES_RETRY_INTERVAL;
    self.retryAttempt = 0;
    self.httpRequestHeaders = headers;
    self.connectMethod = connectMethod;
    self.connectBody = connectBody;
    messageQueue = dispatch_queue_create("com.launchdarkly.eventMessenge-queue", DISPATCH_QUEUE_SERIAL);
    connectionQueue = dispatch_queue_create("com.launchdarkly.eventConnection-queue", DISPATCH_QUEUE_SERIAL);
    self.eventStringAccumulator = [[LDEventStringAccumulator alloc] init];

    return self;
}

- (void)addEventListener:(NSString *)eventName handler:(LDEventSourceEventHandler)handler
{
    if (self.listeners[eventName] == nil) {
        [self.listeners setObject:[NSMutableArray array] forKey:eventName];
    }
    
    [self.listeners[eventName] addObject:handler];
}

- (void)onMessage:(LDEventSourceEventHandler)handler
{
    [self addEventListener:MessageEvent handler:handler];
}

- (void)onError:(LDEventSourceEventHandler)handler
{
    [self addEventListener:ErrorEvent handler:handler];
}

- (void)onOpen:(LDEventSourceEventHandler)handler
{
    [self addEventListener:OpenEvent handler:handler];
}

- (void)onReadyStateChanged:(LDEventSourceEventHandler)handler
{
    [self addEventListener:ReadyStateEvent handler:handler];
}

- (void)close
{
    wasClosed = YES;
    [self.eventSourceTask cancel];
    [self.session finishTasksAndInvalidate];
    [self.listeners removeAllObjects];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        // Opened
        LDEvent *e = [LDEvent new];
        e.readyState = kEventStateOpen;
        
        _retryAttempt = 0;
        [self _dispatchEvent:e type:ReadyStateEvent];
        [self _dispatchEvent:e type:OpenEvent];
    }
    
    if (completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

//替换非utf8字符
//注意：如果是三字节utf-8，第二字节错误，则先替换第一字节内容(认为此字节误码为三字节utf8的头)，然后判断剩下的两个字节是否非法；
- (NSData *)replaceNoUtf8:(NSData *)data
{
    //保存结果
    NSMutableData *resData = [[NSMutableData alloc] initWithCapacity:data.length];

    NSData *replacement = [@"�" dataUsingEncoding:NSUTF8StringEncoding];

    uint64_t index = 0;
    const uint8_t *bytes = data.bytes;

    long dataLength = (long) data.length;

    while (index < dataLength) {
        uint8_t len = 0;
        uint8_t firstChar = bytes[index];

            // 1个字节
        if ((firstChar & 0x80) == 0 && (firstChar == 0x09 || firstChar == 0x0A || firstChar == 0x0D || (0x20 <= firstChar && firstChar <= 0x7E))) {
            len = 1;
        }
            // 2字节
        else if ((firstChar & 0xE0) == 0xC0 && (0xC2 <= firstChar && firstChar <= 0xDF)) {
            if (index + 1 < dataLength) {
                uint8_t secondChar = bytes[index + 1];
                if (0x80 <= secondChar && secondChar <= 0xBF) {
                    len = 2;
                }
            }
        }
            // 3字节
        else if ((firstChar & 0xF0) == 0xE0) {
            if (index + 2 < dataLength) {
                uint8_t secondChar = bytes[index + 1];
                uint8_t thirdChar = bytes[index + 2];
                
                if (firstChar == 0xE0 && (0xA0 <= secondChar && secondChar <= 0xBF) && (0x80 <= thirdChar && thirdChar <= 0xBF)) {
                    len = 3;
                } else if (((0xE1 <= firstChar && firstChar <= 0xEC) || firstChar == 0xEE || firstChar == 0xEF) && (0x80 <= secondChar && secondChar <= 0xBF) && (0x80 <= thirdChar && thirdChar <= 0xBF)) {
                    len = 3;
                } else if (firstChar == 0xED && (0x80 <= secondChar && secondChar <= 0x9F) && (0x80 <= thirdChar && thirdChar <= 0xBF)) {
                    len = 3;
                }
            }
        }
            // 4字节
        else if ((firstChar & 0xF8) == 0xF0) {
            if (index + 3 < dataLength) {
                uint8_t secondChar = bytes[index + 1];
                uint8_t thirdChar = bytes[index + 2];
                uint8_t fourthChar = bytes[index + 3];
                
                if (firstChar == 0xF0) {
                    if ((0x90 <= secondChar & secondChar <= 0xBF) && (0x80 <= thirdChar && thirdChar <= 0xBF) && (0x80 <= fourthChar && fourthChar <= 0xBF)) {
                        len = 4;
                    }
                } else if ((0xF1 <= firstChar && firstChar <= 0xF3)) {
                    if ((0x80 <= secondChar && secondChar <= 0xBF) && (0x80 <= thirdChar && thirdChar <= 0xBF) && (0x80 <= fourthChar && fourthChar <= 0xBF)) {
                        len = 4;
                    }
                } else if (firstChar == 0xF3) {
                    if ((0x80 <= secondChar && secondChar <= 0x8F) && (0x80 <= thirdChar && thirdChar <= 0xBF) && (0x80 <= fourthChar && fourthChar <= 0xBF)) {
                        len = 4;
                    }
                }
            }
        }
            // 5个字节
        else if ((firstChar & 0xFC) == 0xF8) {
            len = 0;
        }
            // 6个字节
        else if ((firstChar & 0xFE) == 0xFC) {
            len = 0;
        }

        if (len == 0) {
            index++;
            [resData appendData:replacement];
        } else {
            [resData appendBytes:bytes + index length:len];
            index += len;
        }
    }

    return resData;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    NSString *eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (!eventString) {
        data = [self replaceNoUtf8:data];
        eventString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if (self.receiveTempString.length && eventString) {
//        const char *cStr = [self.receiveTempString cStringUsingEncoding:NSUTF8StringEncoding];
//        printf("+++收到数据unMatchString: %s \n", cStr);
        eventString = [self.receiveTempString stringByAppendingString:eventString];
        self.receiveTempString = nil;
    }
//    const char *cStr = [eventString cStringUsingEncoding:NSUTF8StringEncoding];
//    printf("+++收到数据: %s \n", cStr);
    if ([eventString containsString:@"event:"]) {
        NSString *pattern = @"^(event:).*(\\n\\n)";
        NSError *error = nil;

        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                               options:NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:&error];

        NSTextCheckingResult *match = [regex firstMatchInString:eventString
                                                        options:0
                                                          range:NSMakeRange(0, [eventString length])];

        if (match) {
            NSRange matchRange = [match range];
            NSString *matchedString = [eventString substringWithRange:matchRange];
            NSString *unMatchString = [eventString stringByReplacingOccurrencesOfString:matchedString withString:@""];
            eventString = matchedString;
            if (unMatchString.length) {
                self.receiveTempString = unMatchString;
            }
        }
        else {
            self.receiveTempString = eventString;
            return;
        }

    }
    @synchronized(self) {
        [self.eventStringAccumulator accumulateEventStringWithString:eventString];
        if ([self.eventStringAccumulator isReadyToParseEvent]) {
            NSString *accumulatedEventString = [self.eventStringAccumulator.eventString copy];
            [self.eventStringAccumulator reset];
            [self parseEventString:accumulatedEventString];
        }
    }
}

- (void)parseEventString:(NSString*)eventString {
    if (eventString.length == 0) { return; }
    LDEventParser *parser = [LDEventParser eventParserWithEventString:eventString];
    if (parser.event) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(messageQueue, ^{
            [weakSelf _dispatchEvent:parser.event];
        });
        if (parser.event.id) {
            self.lastEventID = parser.event.id;
        }
    }
    if (parser.retryInterval != nil) {
        self.retryInterval = [parser.retryInterval doubleValue];
    }
    if (parser.remainingEventString.length > 0 && parser.remainingEventString.hasEventPrefix) {
        [self parseEventString:parser.remainingEventString];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error
{
    self.eventSourceTask = nil;
    
    if (wasClosed) {
        return;
    }
    
    LDEvent *e = [LDEvent new];
    e.readyState = kEventStateClosed;
    e.error = [self eventErrorForTask:task errorCode:e.readyState underlyingError:error];
    
    [self _dispatchEvent:e type:ReadyStateEvent];
    [self _dispatchEvent:e type:ErrorEvent];
    
    if ([self responseIsUnauthorizedForTask:task]) {
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self increaseIntervalWithBackoff] * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_after(popTime, connectionQueue, ^(void){
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf open];
        });
    }
}

- (NSError*)eventErrorForTask:(nonnull NSURLSessionTask *)task errorCode:(NSInteger)errorCode underlyingError:(nullable NSError *)underlyingError
{
    NSError *defaultError = underlyingError ?: [NSError errorWithDomain:@""
                                                       code:errorCode
                                                   userInfo:@{ NSLocalizedDescriptionKey: @"Connection with the event source was closed." }];

    if (![self responseIsUnauthorizedForTask:task]) { return defaultError; }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithDictionary:@{NSLocalizedDescriptionKey: @"Connection refused by the server."}];
    if (underlyingError) { userInfo[NSUnderlyingErrorKey] = underlyingError; }
    NSError *eventError = [NSError errorWithDomain:LDEventSourceErrorDomain
                                              code:-HTTPStatusCodeUnauthorized
                                          userInfo:userInfo.copy];

    return eventError;
}

- (BOOL)responseIsUnauthorizedForTask:(nonnull NSURLSessionTask *)task
{
    if (![task.response isKindOfClass:[NSHTTPURLResponse class]]) { return NO; }
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    return response && response.statusCode == HTTPStatusCodeUnauthorized;
}

- (void)open
{
    wasClosed = NO;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.eventURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:self.timeoutInterval];
    if (self.httpRequestHeaders) {
        for (NSString * key in self.httpRequestHeaders.allKeys){
            [request setValue:self.httpRequestHeaders[key] forHTTPHeaderField:key];
        }
    }
    if (self.lastEventID) {
        [request setValue:self.lastEventID forHTTPHeaderField:@"Last-Event-ID"];
    }

    if (self.connectMethod.length > 0) {
        request.HTTPMethod = self.connectMethod;
    }

    if (self.connectBody.length > 0) {
        request.HTTPBody = self.connectBody;
    }
    
    if (self.session) {
        [self.session invalidateAndCancel];
    }
    self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:[NSOperationQueue currentQueue]];
    
    self.eventSourceTask = [self.session dataTaskWithRequest:request];
    [self.eventSourceTask resume];
    
    LDEvent *e = [LDEvent new];
    e.readyState = kEventStateConnecting;
    
    [self _dispatchEvent:e type:ReadyStateEvent];
}

- (void)_dispatchEvent:(LDEvent *)event type:(NSString * const)type
{
    NSArray *eventHandlers = self.listeners[type];
    for (int i=0; i < eventHandlers.count; i++) {
        LDEventSourceEventHandler handler = eventHandlers[i];
        dispatch_async(connectionQueue, ^{
            handler(event);
        });
    }
}

- (void)_dispatchEvent:(LDEvent *)event
{
    [self _dispatchEvent:event type:MessageEvent];
    
    if (event.event != nil) {
        [self _dispatchEvent:event type:event.event];
    }
}

- (NSTimeInterval)increaseIntervalWithBackoff {
    _retryAttempt++;
    return arc4random_uniform(MIN(ES_MAX_RECONNECT_TIME, _retryInterval * pow(2, _retryAttempt)));
}

@end


@implementation LDEvent

- (NSString *)description
{
    NSString *state = nil;
    switch (self.readyState) {
            case kEventStateConnecting:
            state = @"CONNECTING";
            break;
            case kEventStateOpen:
            state = @"OPEN";
            break;
            case kEventStateClosed:
            state = @"CLOSED";
            break;
    }
    
    return [NSString stringWithFormat:@"<%@: readyState: %@, id: %@; event: %@; data: %@>",
            [self class],
            state,
            self.id,
            self.event,
            self.data];
}

-(id)copyWithZone:(NSZone*)zone {
    LDEvent *copiedEvent = [[LDEvent alloc] init];
    copiedEvent.id = self.id;
    copiedEvent.event = self.event;
    copiedEvent.data = self.data;
    copiedEvent.readyState = self.readyState;
    copiedEvent.error = self.error;
    return copiedEvent;
}

@end

NSString *const MessageEvent = @"message";
NSString *const ErrorEvent = @"error";
NSString *const OpenEvent = @"open";
NSString *const ReadyStateEvent = @"readyState";
