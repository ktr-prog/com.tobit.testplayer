#import "AppDelegate.h"
#import "SearchViewController.h"
#import "RfxSearchService.h"

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[RfxSearchService shared] startAutoload];
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    [self.window setRootViewController:[[[SearchViewController alloc] init] autorelease]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
