#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class RfxJSPlugin;

void RfxToast(NSString *t);
NSDictionary *RfxPluginPathsPublic(void);     // plugin id -> path of its .js in Documents/Plugins (shipped plugins are copied there on first use)
NSString *RfxPluginDirPublic(void);
unsigned long long RfxHash64Public(NSString *s, NSString **hex);

// one running plugin (JavaScriptCore); speaks the ricercar source-plugin protocol 1
@interface RfxPluginHost : NSObject {
    RfxJSPlugin *m_js;
    int m_nextid;
    NSDictionary *m_caps;
    NSString *m_pluginName;
    NSString *m_pluginId;
    NSString *m_iconUrl;
}
@property (nonatomic, retain) NSString *iconUrl;
@property (nonatomic, retain) NSString *pluginId;
@property (nonatomic, retain) NSDictionary *caps;
@property (nonatomic, retain) NSString *pluginName;
- (id)initWithJS:(RfxJSPlugin *)js;
- (void)call:(NSString *)method params:(NSDictionary *)params done:(void (^)(id result, NSString *err))done;
- (void)initializeDone:(void (^)(NSString *err))done;
- (BOOL)has:(NSString *)cap;
@end
