#import "KidoXDockTilePlugin.h"

static NSString * const KidoXDockIconDefaultsSuiteName = @"com.clyapps.KidoX";
static NSString * const KidoXDockIconDefaultsKey = @"KidoX.dockIcon";
static NSString * const KidoXDockIconChangedNotificationName = @"com.clyapps.KidoX.dockIconChanged";

static void KidoXDockTileLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    NSURL *logsDirectoryURL = [[[NSFileManager defaultManager] homeDirectoryForCurrentUser]
        URLByAppendingPathComponent:@"Library/Logs" isDirectory:YES];
    NSURL *logURL = [logsDirectoryURL URLByAppendingPathComponent:@"KidoXDockIcon.log"];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
    NSString *line = [NSString stringWithFormat:@"[%@] [DockTilePlugin] %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:logsDirectoryURL withIntermediateDirectories:YES attributes:nil error:&error];
    if (error != nil) {
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:logURL.path]) {
        [[NSFileManager defaultManager] createFileAtPath:logURL.path contents:nil attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:logURL error:&error];
    if (handle == nil || error != nil) {
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @finally {
        [handle closeFile];
    }
}

@interface KidoXDockTilePlugin ()
@property (nonatomic, strong, nullable) NSDockTile *dockTile;
@property (nonatomic, strong, nullable) id iconChangeObserver;
@property (nonatomic, copy) NSString *currentIconRawValue;
@end

@implementation KidoXDockTilePlugin

- (instancetype)init {
    self = [super init];
    if (self) {
        self.currentIconRawValue = [self savedIconRawValue];
        KidoXDockTileLog(@"init, savedIconRawValue=%@", self.currentIconRawValue);
        __weak typeof(self) weakSelf = self;
        self.iconChangeObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:KidoXDockIconChangedNotificationName
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            NSString *rawValue = notification.userInfo[@"dockIcon"];
            KidoXDockTileLog(@"received notification %@ userInfo=%@", notification.name, notification.userInfo);
            if ([rawValue isKindOfClass:NSString.class]) {
                weakSelf.currentIconRawValue = rawValue;
                KidoXDockTileLog(@"updated currentIconRawValue from notification: %@", rawValue);
            } else {
                KidoXDockTileLog(@"notification missing valid dockIcon, keeping currentIconRawValue=%@", weakSelf.currentIconRawValue);
            }
            [weakSelf updateDockTile];
        }];
        KidoXDockTileLog(@"registered distributed notification observer: %@", KidoXDockIconChangedNotificationName);
    }
    return self;
}

- (void)dealloc {
    KidoXDockTileLog(@"dealloc");
    if (self.iconChangeObserver != nil) {
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:self.iconChangeObserver];
    }
}

- (void)setDockTile:(NSDockTile *)dockTile {
    _dockTile = dockTile;
    KidoXDockTileLog(@"setDockTile: %@ size=%@", dockTile, NSStringFromSize(dockTile.size));
    [self updateDockTile];
}

- (void)updateDockTile {
    NSDockTile *dockTile = self.dockTile;
    if (dockTile == nil) {
        KidoXDockTileLog(@"updateDockTile skipped: dockTile is nil");
        return;
    }

    NSImage *image = [self currentIconImage];
    if (image == nil) {
        KidoXDockTileLog(@"updateDockTile failed: currentIconImage is nil for rawValue=%@", self.currentIconRawValue);
        return;
    }

    NSSize tileSize = dockTile.size;
    if (NSEqualSizes(tileSize, NSZeroSize)) {
        tileSize = NSMakeSize(512.0, 512.0);
    }

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, tileSize.width, tileSize.height)];
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:container.bounds];
    imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    imageView.image = image;
    imageView.imageAlignment = NSImageAlignCenter;
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [container addSubview:imageView];

    dockTile.contentView = container;
    [dockTile display];
    KidoXDockTileLog(@"updateDockTile displayed icon rawValue=%@ tileSize=%@", self.currentIconRawValue, NSStringFromSize(tileSize));
}

- (NSImage *)currentIconImage {
    NSString *resourceName = [self.currentIconRawValue isEqualToString:@"minimal"] ? @"KidoXMinimal" : @"KidoX";
    NSURL *resourceURL = [[self containingAppBundleURL] URLByAppendingPathComponent:
        [NSString stringWithFormat:@"Contents/Resources/%@.icns", resourceName]];
    KidoXDockTileLog(@"loading icon resource rawValue=%@ resourceName=%@ url=%@", self.currentIconRawValue, resourceName, resourceURL.path);

    NSImage *image = [[NSImage alloc] initWithContentsOfURL:resourceURL];
    KidoXDockTileLog(@"loaded icon resource result=%@", image != nil ? @"success" : @"nil");
    return image;
}

- (NSString *)savedIconRawValue {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KidoXDockIconDefaultsSuiteName];
    NSString *rawValue = [defaults stringForKey:KidoXDockIconDefaultsKey];
    KidoXDockTileLog(@"read saved icon rawValue=%@", rawValue ?: @"<nil>");
    return rawValue ?: @"standard";
}

- (NSURL *)containingAppBundleURL {
    NSURL *pluginURL = [NSBundle bundleForClass:self.class].bundleURL;
    NSURL *appURL = [[[pluginURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    KidoXDockTileLog(@"resolved containing app bundle url=%@", appURL.path);
    return appURL;
}

@end
