#import "SearchViewController.h"
#import "RfxSearchService.h"

@implementation SearchViewController {
    UITextField *m_field;
    UITableView *m_table;
    UILabel *m_status;
    NSArray *m_items;
    NSMutableDictionary *m_thumbs;
    int m_gen;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[self view] setBackgroundColor:[UIColor blackColor]];
    m_thumbs = [[NSMutableDictionary alloc] init];
    CGRect b = [[self view] bounds];
    m_field = [[UITextField alloc] initWithFrame:CGRectMake(12, 60, b.size.width - 24, 40)];
    [m_field setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [m_field setBorderStyle:UITextBorderStyleRoundedRect];
    [m_field setPlaceholder:@"Suchen (Titel, Interpret, Album)"];
    [m_field setReturnKeyType:UIReturnKeySearch];
    [m_field setDelegate:self];
    [m_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    [[self view] addSubview:m_field];
    m_status = [[UILabel alloc] initWithFrame:CGRectMake(12, 104, b.size.width - 24, 22)];
    [m_status setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [m_status setFont:[UIFont systemFontOfSize:13]];
    [m_status setTextColor:[UIColor grayColor]];
    [m_status setText:@"YouTube Music wird gestartet ..."];
    [[self view] addSubview:m_status];
    m_table = [[UITableView alloc] initWithFrame:CGRectMake(0, 130, b.size.width, b.size.height - 130) style:UITableViewStylePlain];
    [m_table setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [m_table setBackgroundColor:[UIColor clearColor]];
    [m_table setDataSource:self]; [m_table setDelegate:self];
    [[self view] addSubview:m_table];
}

- (void)textChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fire) object:nil];
    [self performSelector:@selector(fire) withObject:nil afterDelay:0.8];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self fire]; return YES; }

- (void)fire {
    NSString *t = [m_field text];
    if ([t length] < 2) return;
    int gen = ++m_gen;
    [m_status setText:@"Suche ..."];
    [[RfxSearchService shared] searchText:t done:^(NSString *text, NSArray *items) {
        if (gen != m_gen) return;
        [m_items release]; m_items = [items retain];
        [m_status setText:[NSString stringWithFormat:@"%lu Treffer", (unsigned long)[items count]]];
        [m_table reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)[m_items count]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (c == nil) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"] autorelease];
        [c setBackgroundColor:[UIColor clearColor]];
        [[c textLabel] setTextColor:[UIColor whiteColor]];
        [[c detailTextLabel] setTextColor:[UIColor grayColor]];
    }
    NSDictionary *it = [m_items objectAtIndex:ip.row];
    [[c textLabel] setText:[it objectForKey:@"title"]];
    NSString *artist = [it objectForKey:@"artist"];
    NSString *src = [it objectForKey:@"_source"];
    [[c detailTextLabel] setText:[NSString stringWithFormat:@"%@  ·  %@", ([artist isKindOfClass:[NSString class]] ? artist : @""), (src ? src : @"")]];
    NSString *art = [it objectForKey:@"art"];
    UIImage *im = [art isKindOfClass:[NSString class]] ? [m_thumbs objectForKey:art] : nil;
    [[c imageView] setImage:im];
    if (im == nil && [art isKindOfClass:[NSString class]] && [art length]) {
        NSURL *u = [NSURL URLWithString:art];
        if (u != nil) [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            UIImage *img = d ? [UIImage imageWithData:d] : nil;
            if (img == nil) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [m_thumbs setObject:img forKey:art]; [m_table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone]; });
        }] resume];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *it = [m_items objectAtIndex:ip.row];
    [m_status setText:@"Hole Adresse ..."];
    [[RfxSearchService shared] resolveItem:it done:^(NSDictionary *res, NSString *err) {
        NSString *msg = err ? err : [NSString stringWithFormat:@"%@\n%@", [res objectForKey:@"url"], [res objectForKey:@"format"]];
        [m_status setText:err ? @"Fehler" : @"Adresse erhalten"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:[it objectForKey:@"title"] message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }];
}
@end
