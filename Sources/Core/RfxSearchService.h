#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// The search over all loaded source plugins (YouTube Music, Qobuz, ...), without any user interface.
// Items are dictionaries: title, artist, album, duration (s), art (cover url), ref, kind, _plugin (id), _source (name), _note.
@interface RfxSearchService : NSObject
+ (RfxSearchService *)shared;
- (void)startAutoload;                                                       // loads the plugins that are switched on (YouTube Music by default)
- (NSArray *)sources;                                                        // loaded sources that can search: {id, name, note}
- (void)searchText:(NSString *)text done:(void (^)(NSString *text, NSArray *items))done;
- (void)resolveItem:(NSDictionary *)item done:(void (^)(NSDictionary *res, NSString *err))done;   // track.resolve: url, headers, format ...
- (UIImage *)iconForSource:(NSString *)pid;
@end
