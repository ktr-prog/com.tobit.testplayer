// RfxPluginCore -- the source-plugin engine of Radio.fx (JavaScriptCore host, ricercar protocol 1), taken over unchanged
// from KioskView.m and cut loose from the Radio.fx classes.  Manual reference counting (CLANG_ENABLE_OBJC_ARC=NO).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonDigest.h>
#import "RfxPluginCore.h"

void RfxToast(NSString *t) { NSLog(@"[Msg] %@", t); }

static unsigned long long RfxHash64(NSString *s, NSString **hex) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256([data bytes], (CC_LONG)[data length], d);
    unsigned long long v = 0;
    NSMutableString *h = [NSMutableString string];
    for (int i = 0; i < 16; i++) { [h appendFormat:@"%02x", d[i]]; if (i < 8) v = (v << 8) | d[i]; }
    if (hex != NULL) *hex = h;
    return v;
}

static long long RfxItemID(NSString *plugin, NSString *ref) {
    NSString *hex = nil;
    unsigned long long h64 = RfxHash64([NSString stringWithFormat:@"%@|%@", plugin, ref], &hex);
    return -(long long)(h64 & 0x3fffffffffULL) - 100000;
}

// A source plugin written in JavaScript, running inside the app (JavaScriptCore).  The script defines
// handle(method, params) -> Promise and speaks the ricercar plugin protocol 1 method names.  It gets fetchText(url, opts),
// hostLog(text), hostOpen(url) and hostGet/hostSet(key[, value]) (small per-plugin storage).
@interface RfxJSPlugin : NSObject {
    JSContext *m_ctx;
    int m_nextid;
    NSMutableDictionary *m_pending;
    NSString *m_pid;
}
- (id)initWithScript:(NSString *)src pluginId:(NSString *)pid error:(NSString **)err;
- (void)call:(NSString *)method params:(NSDictionary *)params done:(void (^)(id result, NSString *err))done;
@end

// Values file: Documents/Plugins/<plugin>.txt  (same name as the .js).  Lines "NAME = value" (# or // = comment).  They are appended to the
// script as  var NAME = ...;  so they override the empty gaps in the .js; true/false/numbers stay unquoted, everything else becomes a string.
static NSString *RfxPluginValues(NSString *pid) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *path = [[[docs stringByAppendingPathComponent:@"Plugins"] stringByAppendingPathComponent:pid] stringByAppendingPathExtension:@"txt"];
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (txt == nil) return @"";
    NSMutableString *out = [NSMutableString stringWithString:@"\n"];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        if ([line length] == 0 || [line hasPrefix:@"#"] || [line hasPrefix:@"//"]) continue;
        NSRange r = [line rangeOfString:@"="];
        if (r.location == NSNotFound || r.location == 0) continue;
        NSString *key = [[line substringToIndex:r.location] stringByTrimmingCharactersInSet:ws];
        NSString *val = [[line substringFromIndex:r.location + 1] stringByTrimmingCharactersInSet:ws];
        if ([val length] >= 2 && (([val hasPrefix:@"'"] && [val hasSuffix:@"'"]) || ([val hasPrefix:@"\""] && [val hasSuffix:@"\""])))
            val = [val substringWithRange:NSMakeRange(1, [val length] - 2)];
        if ([val length] == 0) continue;                                       // empty = leave the gap as it is
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
        if ([key rangeOfCharacterFromSet:bad].location != NSNotFound) continue;
        BOOL raw2 = [val isEqualToString:@"true"] || [val isEqualToString:@"false"] ||
                    ([val length] < 10 && [val rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound);
        if (raw2) [out appendFormat:@"var %@ = %@;\n", key, val];
        else {
            NSString *e = [val stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            e = [e stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
            [out appendFormat:@"var %@ = '%@';\n", key, e];
        }
    }
    return out;
}

@implementation RfxJSPlugin

- (id)initWithScript:(NSString *)src pluginId:(NSString *)pid error:(NSString **)err {
    self = [super init];
    if (!self) return nil;
    m_nextid = 1;
    m_pending = [[NSMutableDictionary alloc] init];
    m_pid = [pid retain];
    m_ctx = [[JSContext alloc] init];
    __block NSString *firstError = nil;
    RfxJSPlugin *me = self;
    [m_ctx setExceptionHandler:^(JSContext *c, JSValue *ex) { if (firstError == nil) firstError = [[ex toString] retain]; }];
    m_ctx[@"__native_log"] = ^(NSString *t) {
        NSLog(@"[plugin %@] %@", pid, t);
        // also into  Dateien > Radio.fx > Plugins > <plugin>-log.txt  (the on-screen message is too short for long errors)
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
        NSString *lp = [[[docs stringByAppendingPathComponent:@"Plugins"] stringByAppendingPathComponent:pid] stringByAppendingString:@"-log.txt"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *at = [fm attributesOfItemAtPath:lp error:nil];
        if (at != nil && [[at objectForKey:NSFileSize] unsignedLongLongValue] > 200000) [fm removeItemAtPath:lp error:nil];
        if (![fm fileExistsAtPath:lp]) [fm createFileAtPath:lp contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
        if (fh != nil) {
            NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
            [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], t] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    };
    m_ctx[@"__native_open"] = ^(NSString *u) {
        NSURL *url = [NSURL URLWithString:u];
        if (url != nil) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    };
    m_ctx[@"__native_get"] = ^NSString *(NSString *k) {
        return [[NSUserDefaults standardUserDefaults] stringForKey:[NSString stringWithFormat:@"RfxPlugin.%@.%@", pid, k]];
    };
    m_ctx[@"__native_set"] = ^(NSString *k, NSString *v) {
        NSString *key = [NSString stringWithFormat:@"RfxPlugin.%@.%@", pid, k];
        if (v == nil || [v length] == 0) [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        else [[NSUserDefaults standardUserDefaults] setObject:v forKey:key];
    };
    m_ctx[@"__native_fetch"] = ^(int fid, NSString *url, NSString *optsJson) {
        NSDictionary *o = nil;
        if (optsJson != nil) {
            id j = [NSJSONSerialization JSONObjectWithData:[optsJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) o = j;
        }
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        NSString *meth = [o objectForKey:@"method"];
        if (meth != nil) [r setHTTPMethod:meth];
        NSDictionary *hd = [o objectForKey:@"headers"];
        for (NSString *k in hd) [r setValue:[NSString stringWithFormat:@"%@", [hd objectForKey:k]] forHTTPHeaderField:k];
        NSString *body = [o objectForKey:@"body"];
        if (body != nil) [r setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
        [r setTimeoutInterval:30.0];
        [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
            NSString *text = (data != nil) ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
            NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                JSValue *fn = me->m_ctx[@"__fetchDone"];
                if (e != nil) [fn callWithArguments:@[@(fid), @NO, [e localizedDescription], @0]];
                else [fn callWithArguments:@[@(fid), @YES, (text != nil ? text : @""), @(code)]];
            });
        }] resume];
    };
    m_ctx[@"__native_timer"] = ^(int tid, double ms) {
        [me retain];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * 1000000.0)), dispatch_get_main_queue(), ^{
            [me->m_ctx[@"__timerFire"] callWithArguments:@[@(tid)]];
            [me release];
        });
    };
    m_ctx[@"__native_reply"] = ^(int cid, BOOL ok, NSString *payload) {
        NSNumber *key = [NSNumber numberWithInt:cid];
        void (^d)(id, NSString *) = [[me->m_pending objectForKey:key] retain];
        [me->m_pending removeObjectForKey:key];
        if (d == nil) return;
        if (ok) {
            id r = nil;
            if (payload != nil && [payload length] > 0)
                r = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingAllowFragments error:nil];
            d((r == [NSNull null] ? nil : r), nil);
        } else {
            d(nil, payload != nil ? payload : @"Fehler im Plugin");
        }
        [d release];
    };
    NSString *shim =
    @"var __global = this;\n"
    "var global = this, self = this, window = this;\n"
    "if (typeof globalThis === 'undefined') { var globalThis = this; }\n"
    "var module = { exports: {} };\n"
    "var exports = module.exports;\n"
    "var __cbs = {}; var __n = 0;\n"
    "function fetchText(url, opts) { return new Promise(function (res, rej) { var id = ++__n; __cbs[id] = [res, rej];\n"
    "  __native_fetch(id, url, JSON.stringify(opts || {})); }); }\n"
    "function __fetchDone(id, ok, body, status) { var c = __cbs[id]; delete __cbs[id]; if (!c) return;\n"
    "  if (ok) c[0]({ status: status, text: body }); else c[1](new Error(body)); }\n"
    "function hostLog(t) { __native_log(String(t)); }\n"
    "function hostOpen(u) { __native_open(String(u)); }\n"
    "function hostGet(k) { return __native_get(String(k)); }\n"
    "function hostSet(k, v) { __native_set(String(k), v == null ? '' : String(v)); }\n"
    "function __fmt(a) { var o = [], i, v; for (i = 0; i < a.length; i++) { v = a[i];\n"
    "  try { o.push(typeof v === 'string' ? v : JSON.stringify(v)); } catch (e) { o.push(String(v)); } } return o.join(' '); }\n"
    "var console = { log: function () { hostLog(__fmt(arguments)); }, info: function () { hostLog(__fmt(arguments)); },\n"
    "  warn: function () { hostLog(__fmt(arguments)); }, error: function () { hostLog(__fmt(arguments)); }, debug: function () {} };\n"
    "var __timers = {}, __tn = 0;\n"
    "function setTimeout(fn, ms) { var id = ++__tn; __timers[id] = { fn: fn, every: 0 }; __native_timer(id, +ms || 0); return id; }\n"
    "function setInterval(fn, ms) { var id = ++__tn; __timers[id] = { fn: fn, every: +ms || 1 }; __native_timer(id, +ms || 1); return id; }\n"
    "function clearTimeout(id) { delete __timers[id]; }\n"
    "var clearInterval = clearTimeout;\n"
    "function __timerFire(id) { var t = __timers[id]; if (!t) return; if (t.every) __native_timer(id, t.every); else delete __timers[id];\n"
    "  try { t.fn(); } catch (e) { hostLog('timer: ' + e); } }\n"
    "function fetch(url, o) { o = o || {};\n"
    "  return fetchText(String(url), { method: o.method, headers: o.headers, body: o.body == null ? undefined : (typeof o.body === 'string' ? o.body : String(o.body)) }).then(function (r) {\n"
    "    return { ok: r.status >= 200 && r.status < 300, status: r.status, url: String(url),\n"
    "      text: function () { return Promise.resolve(r.text); }, json: function () { return Promise.resolve(JSON.parse(r.text)); } }; }); }\n"
    "var __b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';\n"
    "function btoa(s) { s = String(s); var o = '', i = 0, a, b, c;\n"
    "  while (i < s.length) { a = s.charCodeAt(i++) & 255; b = i < s.length ? s.charCodeAt(i++) & 255 : -1; c = i < s.length ? s.charCodeAt(i++) & 255 : -1;\n"
    "    o += __b64.charAt(a >> 2) + __b64.charAt(((a & 3) << 4) | (b < 0 ? 0 : b >> 4)) + (b < 0 ? '=' : __b64.charAt(((b & 15) << 2) | (c < 0 ? 0 : c >> 6))) + (c < 0 ? '=' : __b64.charAt(c & 63)); }\n"
    "  return o; }\n"
    "function atob(s) { s = String(s).replace(/[^A-Za-z0-9+\\/]/g, ''); var o = '', b = 0, n = 0, i;\n"
    "  for (i = 0; i < s.length; i++) { b = ((b << 6) | __b64.indexOf(s.charAt(i))) & 65535; n += 6; if (n >= 8) { n -= 8; o += String.fromCharCode((b >> n) & 255); } }\n"
    "  return o; }\n"
    "function URLSearchParams(init) { var me = this, k; this.l = [];\n"
    "  if (typeof init === 'string') init.replace(/^\\?/, '').split('&').forEach(function (p) { if (!p) return; var kv = p.split('=');\n"
    "    me.l.push([decodeURIComponent(kv[0]), decodeURIComponent((kv[1] || '').replace(/\\+/g, ' '))]); });\n"
    "  else if (init) for (k in init) this.l.push([k, String(init[k])]); }\n"
    "URLSearchParams.prototype.append = function (k, v) { this.l.push([k, String(v)]); };\n"
    "URLSearchParams.prototype.set = function (k, v) { this.l = this.l.filter(function (e) { return e[0] !== k; }); this.l.push([k, String(v)]); };\n"
    "URLSearchParams.prototype.get = function (k) { for (var i = 0; i < this.l.length; i++) if (this.l[i][0] === k) return this.l[i][1]; return null; };\n"
    "URLSearchParams.prototype.has = function (k) { return this.get(k) !== null; };\n"
    "URLSearchParams.prototype.toString = function () { return this.l.map(function (e) { return encodeURIComponent(e[0]) + '=' + encodeURIComponent(e[1]); }).join('&'); };\n"
    "var __rpcId = 0, __rpcPending = {};\n"
    "function __rpcIn(line) { var m; try { m = typeof line === 'string' ? JSON.parse(line) : line; } catch (e) { return; }\n"
    "  if (m && m.id != null && __rpcPending[m.id]) { var p = __rpcPending[m.id]; delete __rpcPending[m.id]; if (m.error) p[1](m.error); else p[0](m.result); } }\n"
    "var writeLine = function (l) { __rpcIn(l); };\n"
    "var send = writeLine, emit = writeLine, print = writeLine;\n"
    "var process = { stdout: { write: function (l) { String(l).split('\\n').forEach(function (x) { if (x) __rpcIn(x); }); return true; } },\n"
    "  argv: [], env: {}, platform: 'ios', on: function () {} };\n"
    "var stdout = process.stdout;\n"
    "function __adapt() {\n"
    "  if (typeof handle === 'function') return;\n"
    "  var m = module.exports, f = null, o = null, i, c, names, nm;\n"
    "  var cands = [m, m && m.default, __global.plugin, __global.Plugin, __global.source, __global.exports === m ? null : __global.exports];\n"
    "  for (i = 0; i < cands.length && !f; i++) { c = cands[i]; if (!c) continue;\n"
    "    if (typeof c === 'function') { f = c; }\n"
    "    else if (typeof c.handle === 'function') { f = c.handle; o = c; }\n"
    "    else if (typeof c.handleRequest === 'function') { f = c.handleRequest; o = c; }\n"
    "    else if (c.methods && typeof c.methods === 'object') { f = (function (mm) { return function (method, p) { var fn = mm[method]; if (!fn) throw new Error('method not found'); return fn.call(mm, p); }; })(c.methods); }\n"
    "    else if (c.handlers && typeof c.handlers === 'object') { f = (function (mm) { return function (method, p) { var fn = mm[method]; if (!fn) throw new Error('method not found'); return fn.call(mm, p); }; })(c.handlers); } }\n"
    "  if (!f && typeof __global.handleRequest === 'function') f = __global.handleRequest;\n"
    "  if (!f && typeof __global.onRequest === 'function') f = __global.onRequest;\n"
    "  if (!f && __global.methods && typeof __global.methods === 'object') f = (function (mm) { return function (method, p) { var fn = mm[method]; if (!fn) throw new Error('method not found'); return fn.call(mm, p); }; })(__global.methods);\n"
    "  if (!f && __global.handlers && typeof __global.handlers === 'object') f = (function (mm) { return function (method, p) { var fn = mm[method]; if (!fn) throw new Error('method not found'); return fn.call(mm, p); }; })(__global.handlers);\n"
    "  if (!f) { names = ['onMessage', 'onmessage', 'onLine', 'processLine', 'process_line', 'handleLine', 'handleMessage', 'rpc'];\n"
    "    for (i = 0; i < names.length && !f; i++) { nm = names[i];\n"
    "      if (typeof __global[nm] === 'function') { f = __global[nm]; o = null; }\n"
    "      else if (m && typeof m[nm] === 'function') { f = m[nm]; o = m; } }\n"
    "    if (f) f = (function (fn, owner) { return function (method, p) { return new Promise(function (res, rej) {\n"
    "      var id = ++__rpcId, r; __rpcPending[id] = [res, rej];\n"
    "      try { r = fn.call(owner, JSON.stringify({ jsonrpc: '2.0', id: id, method: method, params: p })); } catch (e) { delete __rpcPending[id]; return rej(e); }\n"
    "      Promise.resolve(r).then(function (v) { if (v === undefined || v === null || v === '' || !__rpcPending[id]) return;\n"
    "        delete __rpcPending[id]; var j = typeof v === 'string' ? JSON.parse(v) : v;\n"
    "        if (j && j.error) rej(j.error); else res(j && j.jsonrpc ? j.result : j); }, rej); }); }; })(f, o); }\n"
    "  if (f) { var fo = o, ff = f; __global.handle = function (method, p) { return ff.call(fo, method, p); }; } }\n"
    "function __unwrap(r) { if (r && typeof r === 'object' && r.jsonrpc && !Array.isArray(r)) { if (r.error) throw r.error; if ('result' in r) return r.result; } return r; }\n"
    "function __errText(e) {\n"
    "  if (e && typeof e === 'object' && typeof e.code === 'number') {\n"
    "    var base = { '-32001': 'Anmeldung nötig', '-32002': 'Nicht gefunden', '-32003': 'Nicht verfügbar', '-32004': 'Zu viele Anfragen, später erneut versuchen', '-32005': 'Netzwerkfehler' }[String(e.code)];\n"
    "    var msg = e.message ? String(e.message) : '';\n"
    "    var rs = e.data && e.data.restrictions ? ' [' + [].concat(e.data.restrictions).join(', ') + ']' : '';\n"
    "    return (base ? base + (msg ? ': ' + msg : '') : (msg || ('Fehler ' + e.code))) + rs; }\n"
    "  return String((e && e.message) || e); }\n"
    "function __dispatch(id, method, paramsJson) {\n"
    "  Promise.resolve().then(function () { return __unwrap(handle(method, JSON.parse(paramsJson))); })\n"
    "   .then(function (r) { __native_reply(id, true, JSON.stringify(r === undefined ? null : r)); },\n"
    "         function (e) { __native_reply(id, false, __errText(e)); }); }\n";
    [m_ctx evaluateScript:shim];
    [m_ctx evaluateScript:[src stringByAppendingString:RfxPluginValues(pid)]];
    // ricercar-style scripts (module.exports.handle / methods / onMessage ...) are adapted to handle(method, params)
    if (firstError == nil) [m_ctx evaluateScript:@"__adapt();"];
    if (firstError == nil && [[m_ctx[@"handle"] toString] hasPrefix:@"undefined"]) firstError = [@"Das Plugin definiert weder handle(method, params) noch eine bekannte Ricercar-Schnittstelle (module.exports.handle, methods, onMessage ...)." retain];
    if (firstError != nil) {
        if (err != NULL) *err = [firstError autorelease];
        [self release];
        return nil;
    }
    [m_ctx setExceptionHandler:^(JSContext *c, JSValue *ex) { NSLog(@"[plugin %@] JS-Fehler: %@", pid, ex); }];
    return self;
}

- (void)dealloc {
    [m_ctx release]; [m_pending release]; [m_pid release];
    [super dealloc];
}

- (void)call:(NSString *)method params:(NSDictionary *)params done:(void (^)(id, NSString *))done {
    int cid = m_nextid++;
    [m_pending setObject:[[done copy] autorelease] forKey:[NSNumber numberWithInt:cid]];
    NSData *pj = [NSJSONSerialization dataWithJSONObject:(params != nil ? params : [NSDictionary dictionary]) options:0 error:nil];
    NSString *ps = [[[NSString alloc] initWithData:pj encoding:NSUTF8StringEncoding] autorelease];
    [[m_ctx objectForKeyedSubscript:@"__dispatch"] callWithArguments:@[@(cid), method, ps]];
}

@end


// Documents/Plugins is the one place for plugins. The app ships its plugins in the bundle (Plugins/) and copies each one
// there on start if it is missing; existing files (your edits, keys you typed in) are never overwritten.
// To get a fresh copy of a shipped plugin, delete its file in the Files app.
// The values of <plugin>.txt are also written into the gaps of <plugin>.js itself (the "var NAME = ...;" lines), so the script
// in the Files app shows what is used.  Only lines that exist in the script are changed, and only when the value differs.
static void RfxApplyValuesToScripts(NSString *pdir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [fm contentsOfDirectoryAtPath:pdir error:nil]) {
        if ([[f pathExtension] caseInsensitiveCompare:@"js"] != NSOrderedSame) continue;
        NSString *pid = [f stringByDeletingPathExtension];
        NSString *vals = RfxPluginValues(pid);
        if ([vals length] < 3) continue;
        NSString *jp = [pdir stringByAppendingPathComponent:f];
        NSString *src = [NSString stringWithContentsOfFile:jp encoding:NSUTF8StringEncoding error:nil];
        if (src == nil) continue;
        NSString *out = src;
        NSRegularExpression *pair = [NSRegularExpression regularExpressionWithPattern:@"^var ([A-Z0-9_]+) = (.*);$" options:NSRegularExpressionAnchorsMatchLines error:nil];
        for (NSTextCheckingResult *m in [pair matchesInString:vals options:0 range:NSMakeRange(0, [vals length])]) {
            NSString *key = [vals substringWithRange:[m rangeAtIndex:1]];
            NSString *lit = [vals substringWithRange:[m rangeAtIndex:2]];
            NSString *pat = [NSString stringWithFormat:@"^(var %@ = )(?:'(?:[^'\\\\\\n]|\\\\.)*'|\"(?:[^\"\\\\\\n]|\\\\.)*\"|[^;\\n]*);", key];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:NSRegularExpressionAnchorsMatchLines error:nil];
            if (re == nil) continue;
            NSString *tpl = [NSString stringWithFormat:@"$1%@;", [NSRegularExpression escapedTemplateForString:lit]];
            out = [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, [out length]) withTemplate:tpl];
        }
        if (![out isEqualToString:src]) [out writeToFile:jp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static NSString *RfxPluginDir(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *pdir = [docs stringByAppendingPathComponent:@"Plugins"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:pdir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *shipped = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Plugins"];
    for (NSString *f in [fm contentsOfDirectoryAtPath:shipped error:nil]) {
        if ([[f pathExtension] caseInsensitiveCompare:@"js"] != NSOrderedSame && [[f pathExtension] caseInsensitiveCompare:@"txt"] != NSOrderedSame) continue;
        NSString *dst = [pdir stringByAppendingPathComponent:f];
        if (![fm fileExistsAtPath:dst]) [fm copyItemAtPath:[shipped stringByAppendingPathComponent:f] toPath:dst error:nil];
    }
    RfxApplyValuesToScripts(pdir);
    return pdir;
}


static NSDictionary *RfxPluginPaths(void) {
    NSString *pdir = RfxPluginDir();
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pdir error:nil])
        if ([[f pathExtension] caseInsensitiveCompare:@"js"] == NSOrderedSame)
            [d setObject:[pdir stringByAppendingPathComponent:f] forKey:[f stringByDeletingPathExtension]];
    return d;
}


static void RfxFetchPluginIcon(id urlStr, NSString *pid) {
    if (![urlStr isKindOfClass:[NSString class]] || [urlStr length] == 0 || [pid length] == 0) return;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *dest = [[[docs stringByAppendingPathComponent:@"Plugins"] stringByAppendingPathComponent:pid] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) return;
    NSURL *u = [NSURL URLWithString:urlStr];
    if (u == nil) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *rs, NSError *er) {
        if (d == nil || er != nil) { NSLog(@"[Plugin] icon %@: %@", urlStr, er ? [er localizedDescription] : @"keine Daten"); return; }
        UIImage *img = nil;
        CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)d, NULL);     // .ico: take the largest image of the file
        if (src != NULL) {
            size_t n = CGImageSourceGetCount(src), best = 0, bw = 0;
            for (size_t i = 0; i < n; i++) {
                CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                if (cg != NULL) { if (CGImageGetWidth(cg) >= bw) { bw = CGImageGetWidth(cg); best = i; } CGImageRelease(cg); }
            }
            CGImageRef cg = (n > 0) ? CGImageSourceCreateImageAtIndex(src, best, NULL) : NULL;
            if (cg != NULL) { img = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
            CFRelease(src);
        }
        if (img == nil) img = [UIImage imageWithData:d];
        NSData *png = (img != nil) ? UIImagePNGRepresentation(img) : nil;
        if (png == nil) { NSLog(@"[Plugin] icon %@: Format nicht lesbar", urlStr); return; }
        [[NSFileManager defaultManager] createDirectoryAtPath:[dest stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [png writeToFile:dest atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [[NSNotificationCenter defaultCenter] postNotificationName:@"RfxPluginIconLoaded" object:nil]; });
    }] resume];
}



@implementation RfxPluginHost
@synthesize caps = m_caps, pluginName = m_pluginName, pluginId = m_pluginId, iconUrl = m_iconUrl;

- (id)initWithJS:(RfxJSPlugin *)js {
    self = [super init];
    if (self) { m_js = [js retain]; m_nextid = 1; }
    return self;
}
- (void)dealloc { [m_js release]; [m_caps release]; [m_pluginName release]; [m_pluginId release]; [m_iconUrl release]; [super dealloc]; }

- (BOOL)has:(NSString *)cap { return [[m_caps objectForKey:cap] boolValue]; }

// ricercar protocol 1 error codes as the plugin (bridge) reports them
static NSString *RfxRpcErrorText(id er) {
    if (![er isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"%@", er];
    NSString *msg = [[er objectForKey:@"message"] description];
    NSString *base = nil;
    switch ([[er objectForKey:@"code"] intValue]) {
    case -32001: base = @"Anmeldung nötig"; break;
    case -32002: base = @"Nicht gefunden"; break;
    case -32003: base = @"Nicht verfügbar"; break;
    case -32004: base = @"Zu viele Anfragen, später erneut versuchen"; break;
    case -32005: base = @"Netzwerkfehler"; break;
    }
    NSString *t = (base != nil) ? ([msg length] ? [NSString stringWithFormat:@"%@: %@", base, msg] : base) : ([msg length] ? msg : @"Fehler");
    id rs = [[er objectForKey:@"data"] isKindOfClass:[NSDictionary class]] ? [[er objectForKey:@"data"] objectForKey:@"restrictions"] : nil;
    if ([rs isKindOfClass:[NSArray class]] && [rs count] > 0) t = [t stringByAppendingFormat:@" [%@]", [rs componentsJoinedByString:@", "]];
    return t;
}

// Compatibility layer for ricercar plugins: the wire format is the same, but plugins differ in what they leave out.
// Missing capabilities are assumed, a search answer without groups becomes one group, browse.root without sections gets
// the plugin's library.* lists, browse.list on "library.*" is routed to that method, stream_url/uri count as url.
- (id)Normalize:(NSString *)method result:(id)r {
    if (![r isKindOfClass:[NSDictionary class]]) return r;
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:r];
    if ([method isEqualToString:@"initialize"]) {
        if ([m objectForKey:@"capabilities"] == nil) {
            [m setObject:[NSDictionary dictionaryWithObjectsAndKeys:@YES, @"auth", @YES, @"browse", @YES, @"search", @YES, @"resolve", nil] forKey:@"capabilities"];
        }
        if ([m objectForKey:@"plugin"] == nil && [m objectForKey:@"name"] != nil)
            [m setObject:[NSDictionary dictionaryWithObjectsAndKeys:[m objectForKey:@"name"], @"name", ([m objectForKey:@"id"] ? [m objectForKey:@"id"] : [m objectForKey:@"name"]), @"id", nil] forKey:@"plugin"];
    } else if ([method isEqualToString:@"search"]) {
        if ([m objectForKey:@"groups"] == nil && [[m objectForKey:@"items"] isKindOfClass:[NSArray class]])
            [m setObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"mixed", @"kind", [m objectForKey:@"items"], @"items", nil]] forKey:@"groups"];
    } else if ([method isEqualToString:@"browse.root"]) {
        if ([[m objectForKey:@"sections"] count] == 0) {
            NSMutableArray *sec = [NSMutableArray array];
            if ([self has:@"library"]) {
                NSArray *lib = [NSArray arrayWithObjects:@"albums", @"Alben", @"tracks", @"Titel", @"playlists", @"Playlists", @"artists", @"Künstler", nil];
                for (int i = 0; i + 1 < (int)[lib count]; i += 2)
                    [sec addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"library.%@", [lib objectAtIndex:i]], @"ref", @"folder", @"kind",
                                    [lib objectAtIndex:i + 1], @"title", @NO, @"playable", @YES, @"browsable", nil]];
            }
            id home = [m objectForKey:@"home"];
            if ([home isKindOfClass:[NSArray class]])
                for (id h in home)
                    if ([h isKindOfClass:[NSDictionary class]] && [[h objectForKey:@"ref"] isKindOfClass:[NSString class]] && [h objectForKey:@"title"] != nil)
                        [sec addObject:[NSDictionary dictionaryWithObjectsAndKeys:[h objectForKey:@"ref"], @"ref", @"folder", @"kind", [h objectForKey:@"title"], @"title", @NO, @"playable", @YES, @"browsable", nil]];
            if ([sec count] > 0) [m setObject:sec forKey:@"sections"];
        }
    } else if ([method isEqualToString:@"track.resolve"]) {
        if ([m objectForKey:@"url"] == nil) {
            id u = [m objectForKey:@"stream_url"]; if (u == nil) u = [m objectForKey:@"uri"]; if (u == nil) u = [m objectForKey:@"stream"];
            if ([u isKindOfClass:[NSString class]]) [m setObject:u forKey:@"url"];
        }
    }
    return m;
}

- (void)call:(NSString *)method params:(NSDictionary *)params done:(void (^)(id, NSString *))done {
    NSString *m = method; NSDictionary *p = params;
    NSString *ref = [params objectForKey:@"ref"];
    if ([method isEqualToString:@"browse.list"] && [ref hasPrefix:@"library."]) {
        m = ref;
        p = [NSDictionary dictionaryWithObjectsAndKeys:([params objectForKey:@"offset"] ? [params objectForKey:@"offset"] : @0), @"offset",
             ([params objectForKey:@"limit"] ? [params objectForKey:@"limit"] : @50), @"limit", nil];
    }
    void (^d)(id, NSString *) = [[done copy] autorelease];
    [self rawCall:m params:p done:^(id r, NSString *e) { d((e == nil ? [self Normalize:method result:r] : r), e); }];
}

- (void)rawCall:(NSString *)method params:(NSDictionary *)params done:(void (^)(id, NSString *))done {
    if (m_js != nil) { [m_js call:method params:params done:done]; return; }
    // plugins only run inside the app (JavaScriptCore); there is no connection to outside processes
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"Plugin nicht geladen."); });
}

- (void)initializeDone:(void (^)(NSString *))done {
    NSDictionary *out = [NSDictionary dictionaryWithObjectsAndKeys:@"ios", @"device", [NSNumber numberWithBool:NO], @"bit_perfect",
                         [NSNumber numberWithInt:192000], @"max_rate", [NSNumber numberWithInt:24], @"max_bits",
                         [NSArray arrayWithObjects:@44100, @48000, @88200, @96000, @176400, @192000, nil], @"rates", nil];
    NSDictionary *p = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1], @"protocol",
                       [NSDictionary dictionaryWithObjectsAndKeys:@"radiofx", @"name", @"1.0", @"version", nil], @"host",
                       @"", @"data_dir", @"", @"cache_dir", @"de-DE", @"locale", out, @"output",
                       [NSDictionary dictionary], @"settings", nil];
    [self call:@"initialize" params:p done:^(id result, NSString *e) {
        if (e != nil) { done(e); return; }
        [self setCaps:[result objectForKey:@"capabilities"]];
        [self setPluginName:[[result objectForKey:@"plugin"] objectForKey:@"name"]];
        [self setPluginId:[[result objectForKey:@"plugin"] objectForKey:@"id"]];
        id iu = [[result objectForKey:@"plugin"] objectForKey:@"icon_url"];
        if ([iu isKindOfClass:[NSString class]]) [self setIconUrl:iu];
        done(nil);
    }];
}
@end

NSDictionary *RfxPluginPathsPublic(void) { return RfxPluginPaths(); }
NSString *RfxPluginDirPublic(void) { return RfxPluginDir(); }
unsigned long long RfxHash64Public(NSString *s, NSString **hex) { return RfxHash64(s, hex); }

#pragma mark - search service

#import "RfxSearchService.h"

static RfxSearchService *gRfxSS = nil;

@interface RfxSearchService () {
    NSMutableDictionary *m_hosts;      // id -> RfxPluginHost (loaded)
    NSMutableSet *m_loading;
    BOOL m_started;
}
@end

@implementation RfxSearchService

+ (RfxSearchService *)shared {
    if (gRfxSS == nil) gRfxSS = [[RfxSearchService alloc] init];
    return gRfxSS;
}
- (id)init {
    self = [super init];
    if (self) { m_hosts = [[NSMutableDictionary alloc] init]; m_loading = [[NSMutableSet alloc] init]; }
    return self;
}

// the plugins that start by themselves: what the user switched on; never configured = YouTube Music only
- (NSArray *)autostartList {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:@"RfxPluginAutostart"];
    if (a == nil) a = [NSArray arrayWithObject:@"ytmusic"];
    NSDictionary *paths = RfxPluginPaths();
    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *n in a) if ([paths objectForKey:n] != nil) [ok addObject:n];
    return ok;
}

- (void)load:(NSString *)name done:(void (^)(RfxPluginHost *))done {
    RfxPluginHost *h = [m_hosts objectForKey:name];
    if (h != nil) { if (done) done(h); return; }
    if ([m_loading containsObject:name]) { if (done) done(nil); return; }
    NSString *path = [RfxPluginPaths() objectForKey:name];
    NSString *src = (path != nil) ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    if (src == nil) { RfxToast([NSString stringWithFormat:@"Plugin %@ nicht gefunden.", name]); if (done) done(nil); return; }
    NSString *err = nil;
    RfxJSPlugin *js = [[RfxJSPlugin alloc] initWithScript:src pluginId:name error:&err];
    if (js == nil) { RfxToast([NSString stringWithFormat:@"Plugin %@: %@", name, err]); if (done) done(nil); return; }
    RfxPluginHost *host = [[[RfxPluginHost alloc] initWithJS:js] autorelease];
    [js release];
    [m_loading addObject:name];
    void (^d)(RfxPluginHost *) = done ? [[done copy] autorelease] : nil;
    [host initializeDone:^(NSString *e) {
        [m_loading removeObject:name];
        if (e != nil) { RfxToast([NSString stringWithFormat:@"Plugin %@: %@", name, e]); if (d) d(nil); return; }
        [m_hosts setObject:host forKey:name];
        RfxFetchPluginIcon([host iconUrl], name);
        if (d) d(host);
    }];
}

- (void)startAutoload {
    if (m_started) return;
    m_started = YES;
    for (NSString *n in [self autostartList]) [self load:n done:nil];
}

- (NSArray *)sources {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [[m_hosts allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        RfxPluginHost *h = [m_hosts objectForKey:n];
        if (![h has:@"search"]) continue;
        NSString *pn = [[[h pluginName] componentsSeparatedByString:@" ("] objectAtIndex:0];
        if ([pn length] == 0) pn = n;
        NSString *rn = [[NSUserDefaults standardUserDefaults] stringForKey:[@"RfxSrcNote." stringByAppendingString:n]];
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:n, @"id", pn, @"name", ([rn length] ? rn : @""), @"note", nil]];
    }
    return out;
}

- (UIImage *)iconForSource:(NSString *)pid {
    NSString *p = [[[RfxPluginDir() stringByAppendingPathComponent:pid] stringByAppendingPathExtension:@"png"] retain];
    UIImage *im = [UIImage imageWithContentsOfFile:p];
    [p release];
    return im;
}

- (void)searchText:(NSString *)text done:(void (^)(NSString *, NSArray *))done {
    NSString *t = [[text copy] autorelease];
    void (^d)(NSString *, NSArray *) = [[done copy] autorelease];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([m_hosts count] == 0 && [m_loading count] == 0) { m_started = NO; [self startAutoload]; }
        if ([m_hosts count] == 0) {           // plugins are still starting: look again in a moment (at most ~10 s)
            [self waitAndSearch:t done:d tries:0];
            return;
        }
        [self fire:t done:d];
    });
}

- (void)waitAndSearch:(NSString *)text done:(void (^)(NSString *, NSArray *))done tries:(int)tries {
    if ([m_hosts count] > 0) { [self fire:text done:done]; return; }
    if (tries > 40) { done(text, [NSArray array]); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self waitAndSearch:text done:done tries:tries + 1]; });
}

- (void)fire:(NSString *)text done:(void (^)(NSString *, NSArray *))done {
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSString *n in [[m_hosts allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) if ([[m_hosts objectForKey:n] has:@"search"]) [hosts addObject:n];
    if ([hosts count] == 0 || [text length] == 0) { done(text, [NSArray array]); return; }
    __block int waiting = (int)[hosts count];
    NSMutableDictionary *byPlugin = [NSMutableDictionary dictionary];
    for (NSString *n in hosts) {
        RfxPluginHost *h = [m_hosts objectForKey:n];
        NSDictionary *p = [NSDictionary dictionaryWithObjectsAndKeys:text, @"query", [NSArray arrayWithObjects:@"track", nil], @"kinds",
                           [NSNumber numberWithInt:0], @"offset", [NSNumber numberWithInt:20], @"limit", nil];
        [h call:@"search" params:p done:^(id r, NSString *e) {
            NSMutableArray *mine = [NSMutableArray array];
            NSString *note = nil;
            if (e == nil && [r isKindOfClass:[NSDictionary class]]) {
                id snote = [r objectForKey:@"source_note"];       // e.g. "Premium" / "Free": shown behind the service name
                if ([snote isKindOfClass:[NSString class]] && [snote length]) {
                    note = snote;
                    [[NSUserDefaults standardUserDefaults] setObject:snote forKey:[@"RfxSrcNote." stringByAppendingString:n]];
                }
                for (NSDictionary *g in [r objectForKey:@"groups"]) {
                    if (![[g objectForKey:@"kind"] isEqualToString:@"track"]) continue;       // single titles only
                    for (NSDictionary *it in [g objectForKey:@"items"]) {
                        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:it];
                        [m setObject:n forKey:@"_plugin"];
                        NSString *sn = [[[h pluginName] componentsSeparatedByString:@" ("] objectAtIndex:0];
                        if ([sn length]) [m setObject:sn forKey:@"_source"];
                        if (note != nil) [m setObject:note forKey:@"_note"];
                        if ([m objectForKey:@"kind"] == nil) [m setObject:@"track" forKey:@"kind"];
                        [mine addObject:m];
                    }
                }
            }
            if (e != nil) RfxToast([NSString stringWithFormat:@"Plugin-Suche %@: %@", n, e]);
            [byPlugin setObject:mine forKey:n];
            if (--waiting == 0) {
                NSMutableArray *all = [NSMutableArray array];
                for (NSString *pn in hosts) [all addObjectsFromArray:[byPlugin objectForKey:pn]];      // grouped by source, in the order of the sources
                done(text, all);
            }
        }];
    }
}

- (void)resolveItem:(NSDictionary *)item done:(void (^)(NSDictionary *, NSString *))done {
    RfxPluginHost *h = [m_hosts objectForKey:[item objectForKey:@"_plugin"]];
    void (^d)(NSDictionary *, NSString *) = [[done copy] autorelease];
    if (h == nil || [item objectForKey:@"ref"] == nil) { d(nil, @"Plugin nicht geladen."); return; }
    NSDictionary *p = [NSDictionary dictionaryWithObjectsAndKeys:[item objectForKey:@"ref"], @"ref", @"play", @"purpose", nil];
    [h call:@"track.resolve" params:p done:^(id r, NSString *e) {
        if (e != nil || ![r isKindOfClass:[NSDictionary class]] || ![[r objectForKey:@"url"] isKindOfClass:[NSString class]]) { d(nil, e ? e : @"keine Adresse"); return; }
        d(r, nil);
    }];
}
@end
