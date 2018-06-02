//
//  TKWebServerManager.m
//  WeChatPlugin
//
//  Created by TK on 2018/3/18.
//  Copyright © 2018年 tk. All rights reserved.
//

#import "TKWebServerManager.h"
#import "WeChatPlugin.h"
#import <GCDWebServer.h>
#import <GCDWebServerDataResponse.h>
#import <GCDWebServerURLEncodedFormRequest.h>

@interface TKWebServerManager ()

@property (nonatomic, strong) GCDWebServer *webServer;
@end

@implementation TKWebServerManager

+ (instancetype)shareManager {
    static TKWebServerManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[TKWebServerManager alloc] init];
    });
    return manager;
}

- (void)startServer {
    if (self.webServer) {
        return;
    }
    NSDictionary *options = @{GCDWebServerOption_Port: @52700,
                              GCDWebServerOption_BindToLocalhost: @YES,
                              GCDWebServerOption_ConnectedStateCoalescingInterval: @2,
                              };
    
    self.webServer = [[GCDWebServer alloc] init];
    [self addHandleForSearchUser];
    [self addHandleForOpenSession];
    [self addHandleForSendMsg];
    [self.webServer startWithOptions:options error:nil];
}

- (void)endServer {
    if( [self.webServer isRunning] ) {
        [self.webServer stop];
        [self.webServer removeAllHandlers];
        self.webServer = nil;
    }
}

- (void)addHandleForSearchUser {
    __weak typeof(self) weakSelf = self;
    
    [self.webServer addHandlerForMethod:@"GET" path:@"/wechat-plugin/user" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerRequest * _Nonnull request) {
        
        NSDictionary *keyword = request.query ? request.query[@"keyword"] ? request.query[@"keyword"] : @"" : @"";
        __block NSMutableArray *sessionList = [NSMutableArray array];
        __block BOOL hasResult = NO;
        MMComplexContactSearchTaskMgr *searchMgr = [objc_getClass("MMComplexContactSearchTaskMgr") sharedInstance];
        [searchMgr doComplexContactSearch:keyword searchScene:31 complete:^(NSArray<MMComplexContactSearchResult *> *contactResult, NSArray<MMComplexContactSearchResult *> *brandSult, NSArray<MMComplexGroupContactSearchResult *> *groupResult) {
            [contactResult enumerateObjectsUsingBlock:^(MMComplexContactSearchResult * _Nonnull contact, NSUInteger idx, BOOL * _Nonnull stop) {
                [sessionList addObject:[weakSelf dictFromContactSearchResult:contact]];
            }];
            
            [groupResult enumerateObjectsUsingBlock:^(MMComplexGroupContactSearchResult * _Nonnull group, NSUInteger idx, BOOL * _Nonnull stop) {
                [sessionList addObject:[weakSelf dictFromGroupSearchResult:group]];
            }];
            
            [brandSult enumerateObjectsUsingBlock:^(MMComplexContactSearchResult * _Nonnull contact, NSUInteger idx, BOOL * _Nonnull stop) {
                [sessionList addObject:[weakSelf dictFromContactSearchResult:contact]];
            }];

            hasResult = YES;
        } cancelable:YES];
        
        while (!hasResult) {}
        
        return [GCDWebServerDataResponse responseWithJSONObject:sessionList];
    }];
}

- (void)addHandleForOpenSession {
    [self.webServer addHandlerForMethod:@"POST" path:@"/wechat-plugin/open-session" requestClass:[GCDWebServerURLEncodedFormRequest class] processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerURLEncodedFormRequest * _Nonnull request) {
        NSDictionary *requestBody = [request arguments];
        
        if (requestBody && requestBody[@"userId"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MMSessionMgr *sessionMgr = [[objc_getClass("MMServiceCenter") defaultCenter] getService:objc_getClass("MMSessionMgr")];
                WCContactData *selectContact = [sessionMgr getContact:requestBody[@"userId"]];
                
                WeChat *wechat = [objc_getClass("WeChat") sharedInstance];
                if ([selectContact isBrandContact]) {
                    WCContactData *brandsessionholder  = [sessionMgr getContact:@"brandsessionholder"];
                    if (brandsessionholder) {
                        [wechat startANewChatWithContact:brandsessionholder];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            MMBrandChatsViewController *brandChats = wechat.chatsViewController.brandChatsViewController;
                            [brandChats startChatWithContact:selectContact];
                        });
                    }
                } else {
                    [wechat startANewChatWithContact:selectContact];
                }
                [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
            });
            return [GCDWebServerResponse responseWithStatusCode:200];
        }
        
        return [GCDWebServerResponse responseWithStatusCode:404];
    }];
}

- (void)addHandleForSendMsg {
    [self.webServer addHandlerForMethod:@"POST" path:@"/wechat-plugin/send-message" requestClass:[GCDWebServerURLEncodedFormRequest class] processBlock:^GCDWebServerResponse * _Nullable(__kindof GCDWebServerURLEncodedFormRequest * _Nonnull request) {
        NSDictionary *requestBody = [request arguments];
        if (requestBody && requestBody[@"userId"] && requestBody[@"content"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MessageService *messageService = [[objc_getClass("MMServiceCenter") defaultCenter] getService:objc_getClass("MessageService")];
                NSString *currentUserName = [objc_getClass("CUtility") GetCurrentUserName];
                [messageService SendTextMessage:currentUserName
                                      toUsrName:requestBody[@"userId"]
                                        msgText:requestBody[@"content"]
                                     atUserList:nil];
            });
            return [GCDWebServerResponse responseWithStatusCode:200];
        }
        
        return [GCDWebServerResponse responseWithStatusCode:404];
    }];
}

- (NSDictionary *)dictFromGroupSearchResult:(MMComplexGroupContactSearchResult *)result {
    WCContactData *groupContact = result.groupContact;
    
    __block NSString *subTitle = @"";
    if (result.searchType == 2) {
        [result.groupMembersResult.membersSearchReults enumerateObjectsUsingBlock:^(MMComplexContactSearchResult * _Nonnull contact, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *matchStr =[self matchWithContactResult:contact];
            subTitle = [NSString stringWithFormat:@"%@%@(%@)", TKLocalizedString(@"assistant.search.member"), contact.contact.m_nsNickName, matchStr];
        }];
    }
    
    NSString *imgPath = [self cacheAvatarPathFromHeadImgUrl:groupContact.m_nsHeadImgUrl];
    
    return @{@"title": [NSString stringWithFormat:@"%@%@", TKLocalizedString(@"assistant.search.group"), groupContact.getGroupDisplayName],
             @"subTitle": subTitle,
             @"icon": imgPath,
             @"userId": groupContact.m_nsUsrName
             };
}

- (NSString *)matchWithContactResult:(MMComplexContactSearchResult *)result {
    NSString *matchStr = @"";
    NSInteger type = result.fieldType;
    
    switch (type) {     //     1：备注 3：昵称 4：微信号 7：市 8：省份 9：国家
        case 1:
            matchStr = WXLocalizedString(@"Search.Remark");
            break;
        case 3:
            matchStr = WXLocalizedString(@"Search.Nickname");
            break;
        case 4:
            matchStr = WXLocalizedString(@"Search.Username");
            break;
        case 7:
            matchStr = WXLocalizedString(@"Search.City");
            break;
        case 8:
            matchStr = WXLocalizedString(@"Search.Province");
            break;
        case 9:
            matchStr = WXLocalizedString(@"Search.Country");
            break;
        default:
            matchStr = WXLocalizedString(@"Search.Include");
            break;
    }
    matchStr = [matchStr stringByAppendingString:result.fieldValue];
    return matchStr;
}

- (NSDictionary *)dictFromContactSearchResult:(MMComplexContactSearchResult *)result {
    WCContactData *contact = result.contact;
    
    NSString *title = [contact isBrandContact] ? [NSString stringWithFormat:@"%@%@",TKLocalizedString(@"assistant.search.official"), contact.m_nsNickName] : contact.m_nsNickName;
    if(contact.m_nsRemark && ![contact.m_nsRemark isEqualToString:@""]) {
        title = [NSString stringWithFormat:@"%@(%@)",contact.m_nsRemark, contact.m_nsNickName];
    }
    
    NSString *subTitle =[self matchWithContactResult:result];
    NSString *imgPath = [self cacheAvatarPathFromHeadImgUrl:contact.m_nsHeadImgUrl];
    
    return @{@"title": title,
             @"subTitle": subTitle,
             @"icon": imgPath,
             @"userId": contact.m_nsUsrName
             };
}

//  获取本地图片缓存路径
- (NSString *)cacheAvatarPathFromHeadImgUrl:(NSString *)imgUrl {
    NSString *imgPath = @"";
    if ([imgUrl respondsToSelector:@selector(md5String)]) {
        NSString *imgMd5Str = [imgUrl performSelector:@selector(md5String)];
        MMAvatarService *avatarService = [[objc_getClass("MMServiceCenter") defaultCenter] getService:objc_getClass("MMAvatarService")];
        imgPath = [NSString stringWithFormat:@"%@%@",[avatarService avatarCachePath], imgMd5Str];
    }
    return imgPath;
}

@end
