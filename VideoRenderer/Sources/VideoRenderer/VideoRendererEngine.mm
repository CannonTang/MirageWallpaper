#import "VideoRendererEngine.h"
#import "VRMemoryAssetLoader.h"

#import <QuartzCore/QuartzCore.h>

NSString *const VRVideoEngineErrorDomain = @"VideoRenderer.Engine";

enum {
    VRVideoEngineErrorInvalidManifest = 1,
    VRVideoEngineErrorCannotQueueItem,
};

// KVO contexts. -canInsertItem:afterItem: only validates queue constraints, so
// a truncated/garbage/unsupported file queues fine and then never produces a
// frame — the wallpaper reports success and the user gets a permanently black
// desktop with nothing on stderr or the control channel. These are the two
// signals that actually report decode failure: AVPlayerLooper fails when it
// cannot load the template asset (the common case for a bad file), and the
// current AVPlayerItem fails for anything that survives to enqueue. Note the
// looper plays COPIES of the template item, so observing the template's own
// status would never fire.
static void *kVRLooperStatusContext = &kVRLooperStatusContext;
static void *kVRCurrentItemStatusContext = &kVRCurrentItemStatusContext;

// AVPlayerLooper restarts the media continuously, so end-of-item fires once per
// loop. The consumer writes a line to stdout for each one; rate-limit so a
// short clip cannot spin the control channel.
static const CFTimeInterval kVRMinItemEndInterval = 0.5;

static NSError *VRVideoEngineError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:VRVideoEngineErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static AVLayerVideoGravity VRLayerGravityForFillMode(VRVideoFillMode mode) {
    switch (mode) {
    case VRVideoFillModeContain: return AVLayerVideoGravityResizeAspect;
    case VRVideoFillModeStretch: return AVLayerVideoGravityResize;
    case VRVideoFillModeCover:
    default: return AVLayerVideoGravityResizeAspectFill;
    }
}

static float VRClampVolume(float value) {
    if (!isfinite(value)) return 1.0f;
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

@interface VRVideoRendererEngine ()
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, assign) VRVideoFillMode fillMode;
@property (nonatomic, assign) BOOL autoplay;
@property (nonatomic, assign) BOOL loadFromMemory;
@property (nonatomic, strong) VRMemoryAssetLoader *memoryAssetLoader;
@property (nonatomic, strong) NSMutableArray<id> *itemEndObservers;
@property (nonatomic, strong) id itemFailedObserver;
@property (nonatomic, assign) BOOL looperObserved;
@property (nonatomic, assign) BOOL failureReported;
@property (nonatomic, assign) CFTimeInterval lastItemEndReport;
- (void)detachLooperObserver;
- (void)removeItemEndObservers;
- (void)installItemEndObserversForLooper:(AVPlayerLooper *)looper;
- (void)handleItemDidPlayToEnd;
- (void)reportPlaybackFailure:(NSError *)error fallback:(NSString *)fallback;
@end

@implementation VRVideoRendererEngine

+ (VRVideoEngineConfig)defaultConfig {
    VRVideoEngineConfig config;
    config.fillMode = VRVideoFillModeCover;
    config.initialVolume = 1.0f;
    config.muted = NO;
    config.autoplay = YES;
    config.loadFromMemory = NO;
    return config;
}

- (instancetype)initWithFrame:(NSRect)frameRect config:(VRVideoEngineConfig)config {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer = [CALayer layer];
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;

        _player = [AVQueuePlayer queuePlayerWithItems:@[]];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _player.automaticallyWaitsToMinimizeStalling = YES;
        _player.volume = VRClampVolume(config.initialVolume);
        _player.muted = config.muted;

        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.frame = self.bounds;
        _playerLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        _playerLayer.backgroundColor = NSColor.blackColor.CGColor;
        _playerLayer.needsDisplayOnBoundsChange = NO;
        [self.layer addSublayer:_playerLayer];

        _volume = _player.volume;
        _muted = config.muted;
        _autoplay = config.autoplay;
        _loadFromMemory = config.loadFromMemory;
        _itemEndObservers = [NSMutableArray array];
        [self setFillMode:config.fillMode];

        // The player outlives every wallpaper this engine opens, so these two
        // registrations are made once here and torn down once in -dealloc.
        [_player addObserver:self
                  forKeyPath:@"currentItem.status"
                     options:NSKeyValueObservingOptionNew
                     context:kVRCurrentItemStatusContext];
        __weak __typeof__(self) weakSelf = self;
        _itemFailedObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification * _Nonnull note) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || note.object == nil) return;
            if (![strongSelf.player.items containsObject:note.object]) return;
            [strongSelf reportPlaybackFailure:note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                                     fallback:@"video stopped: failed to play to end"];
        }];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)layout {
    [super layout];
    self.playerLayer.frame = self.bounds;
}

// KVO and NSNotification registrations that survive -dealloc crash the process,
// so every one of them is undone here. Ivars only, no property accessors.
- (void)dealloc {
    [_player removeObserver:self
                 forKeyPath:@"currentItem.status"
                    context:kVRCurrentItemStatusContext];
    if (_looperObserved) {
        [_looper removeObserver:self forKeyPath:@"status" context:kVRLooperStatusContext];
        _looperObserved = NO;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_itemFailedObserver != nil) {
        [center removeObserver:_itemFailedObserver];
        _itemFailedObserver = nil;
    }
    for (id observer in _itemEndObservers) {
        [center removeObserver:observer];
    }
    [_itemEndObservers removeAllObjects];
    [_player pause];
    [_player removeAllItems];
}

#pragma mark - Failure reporting

- (void)detachLooperObserver {
    if (!self.looperObserved) return;
    [self.looper removeObserver:self forKeyPath:@"status" context:kVRLooperStatusContext];
    self.looperObserved = NO;
}

- (void)reportPlaybackFailure:(NSError *)error fallback:(NSString *)fallback {
    if (self.failureReported) return;
    self.failureReported = YES;
    NSString *message = error.localizedDescription.length > 0 ? error.localizedDescription : fallback;
    fprintf(stderr, "VideoRenderer: playback failed: %s\n", message.UTF8String ?: "unknown error");
    if (self.videoDidFailBlock) self.videoDidFailBlock(message);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == kVRCurrentItemStatusContext) {
        AVPlayerItem *current = self.player.currentItem;
        if (current != nil && current.status == AVPlayerItemStatusFailed) {
            [self reportPlaybackFailure:current.error fallback:@"video item failed to load"];
        }
        return;
    }
    if (context == kVRLooperStatusContext) {
        AVPlayerLooper *looper = (AVPlayerLooper *)object;
        if (looper.status == AVPlayerLooperStatusFailed) {
            [self reportPlaybackFailure:looper.error
                               fallback:@"video could not be decoded or looped"];
            return;
        }
        // Re-scope the end-of-item observers: the items the looper actually
        // plays only exist once it leaves the unknown state.
        [self installItemEndObserversForLooper:looper];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

#pragma mark - End of item

- (void)removeItemEndObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (id observer in self.itemEndObservers) {
        [center removeObserver:observer];
    }
    [self.itemEndObservers removeAllObjects];
}

- (void)installItemEndObserversForLooper:(AVPlayerLooper *)looper {
    [self removeItemEndObservers];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak __typeof__(self) weakSelf = self;
    // AVPlayerLooper plays COPIES of the template item, so these are the only
    // items that ever post the notification for us. Scoping the observer to
    // each of them keeps it off every other AVPlayerItem in the process.
    for (AVPlayerItem *looped in looper.loopingPlayerItems) {
        [self.itemEndObservers addObject:
            [center addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                object:looped
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                [weakSelf handleItemDidPlayToEnd];
            }]];
    }
    if (self.itemEndObservers.count > 0) return;
    // The looper is not ready yet (or exposes no items): keep a filtered
    // process-wide observer so the event is never silently lost.
    [self.itemEndObservers addObject:
        [center addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification * _Nonnull note) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || note.object == nil) return;
            if (![strongSelf.player.items containsObject:note.object]) return;
            [strongSelf handleItemDidPlayToEnd];
        }]];
}

- (void)handleItemDidPlayToEnd {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastItemEndReport > 0 && (now - self.lastItemEndReport) < kVRMinItemEndInterval) return;
    self.lastItemEndReport = now;
    if (self.videoDidEndBlock) self.videoDidEndBlock();
}

- (BOOL)openWallpaper:(VRVideoManifest *)manifest error:(NSError **)error {
    if (manifest == nil || manifest.videoURL == nil) {
        if (error != NULL) *error = VRVideoEngineError(VRVideoEngineErrorInvalidManifest,
                                                       @"invalid video wallpaper manifest");
        return NO;
    }

    [self.player pause];
    [self.player removeAllItems];
    [self removeItemEndObservers];
    [self detachLooperObserver];
    self.looper = nil;
    self.memoryAssetLoader = nil;
    self.loaded = NO;
    self.failureReported = NO;
    self.lastItemEndReport = 0;

    NSDictionary *assetOptions = @{
        AVURLAssetPreferPreciseDurationAndTimingKey: @NO,
    };
    NSURL *assetURL = manifest.videoURL;
    if (self.loadFromMemory) {
        VRMemoryAssetLoader *loader = [VRMemoryAssetLoader loaderWithFileURL:manifest.videoURL
                                                                       error:error];
        if (loader == nil) return NO;
        self.memoryAssetLoader = loader;
        assetURL = loader.assetURL;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:assetURL options:assetOptions];
    [self.memoryAssetLoader attachToAsset:asset];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];

    if (![self.player canInsertItem:item afterItem:nil]) {
        if (error != NULL) {
            *error = VRVideoEngineError(VRVideoEngineErrorCannotQueueItem,
                                        [NSString stringWithFormat:@"cannot queue video: %@",
                                                                   manifest.videoURL.path]);
        }
        return NO;
    }

    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];
    self.player.volume = self.volume;
    self.player.muted = self.muted;
    self.loaded = YES;

    // Initial delivery arms the fallback end-of-item observer immediately and
    // reports a looper that has already failed; the Ready transition then
    // re-scopes the observers to the items the looper actually plays.
    // NSKeyValueObservingOptionInitial delivers SYNCHRONOUSLY from inside
    // -addObserver:, so the flag has to be set first: an already-failed looper
    // reports the failure from that call, and a handler that re-enters
    // -openWallpaper: would otherwise reach -detachLooperObserver with the flag
    // still NO, skip the removal, and leave the looper deallocating with a live
    // KVO registration.
    self.looperObserved = YES;
    [self.looper addObserver:self
                  forKeyPath:@"status"
                     options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                     context:kVRLooperStatusContext];

    if (self.autoplay) [self play];
    return YES;
}

// No NSProcessInfo activity assertion: this is background desktop decoration.
// Holding one for the whole playback lifetime raised the process to
// UserInitiated QoS and disabled App Nap, timer coalescing and automatic
// termination. AVPlayer already takes the assertions it actually needs while
// it has frames to present, and a wallpaper that gets throttled while it is
// fully occluded is the desired behaviour, not a bug.
- (void)play {
    if (!self.loaded) return;
    [self.player play];
}

- (void)pause {
    [self.player pause];
}

- (void)setVolume:(float)volume {
    _volume = VRClampVolume(volume);
    self.player.volume = _volume;
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    self.player.muted = muted;
}

- (void)setFillMode:(VRVideoFillMode)fillMode {
    _fillMode = fillMode;
    self.playerLayer.videoGravity = VRLayerGravityForFillMode(fillMode);
}

@end
