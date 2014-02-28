//
//  SCVideoPlayerView.m
//  SCAudioVideoRecorder
//
//  Created by Simon CORSIN on 8/30/13.
//  Copyright (c) 2013 rFlex. All rights reserved.
//

#import "SCVideoPlayerView.h"


////////////////////////////////////////////////////////////
// PRIVATE DEFINITION
/////////////////////

@interface SCVideoPlayerView() {
	UIView * _loadingView;
}

@property (strong, nonatomic, readwrite) SCPlayer * player;
@property (strong, nonatomic, readwrite) AVPlayerLayer * playerLayer;

@end

////////////////////////////////////////////////////////////
// IMPLEMENTATION
/////////////////////

@implementation SCVideoPlayerView

@synthesize player;
@synthesize playerLayer;

- (id) init {
	self = [super init];
	
	if (self) {
		_loadingView = nil;
		[self commonInit];
	}
	
	return self;
}

- (void) dealloc {
	[self.player cleanUp];
	self.playerLayer.player = nil;
}

- (id) initWithCoder:(NSCoder *)aDecoder {
	self = [super initWithCoder:aDecoder];
	
	if (self) {
		[self commonInit];
	}
	
	return self;
}

- (void) commonInit {
    UITapGestureRecognizer *tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapGestureRecognizerHandle:)];
    [self addGestureRecognizer:tapGestureRecognizer];
    
	self.player = [SCPlayer player];
	self.player.delegate = self;
	self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
	self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	[self.layer addSublayer:self.playerLayer];
	
	UIView * theLoadingView = [[UIView alloc] init];
	theLoadingView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
	
	UIActivityIndicatorView * theIndicatorView = [[UIActivityIndicatorView alloc] init];
	[theIndicatorView startAnimating];
	theIndicatorView.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
	
	[theLoadingView addSubview:theIndicatorView];
	
	self.loadingView = theLoadingView;
	self.loadingView.hidden = YES;
	self.clipsToBounds = YES;
}

#pragma mark - Gesture

- (void)tapGestureRecognizerHandle:(UITapGestureRecognizer *)tapGestureRecognizer {
    switch (tapGestureRecognizer.state) {
        case UIGestureRecognizerStateEnded:
            if (self.player.isPlaying) {
                [self.player pause];
            } else {
                [self.player play];
            }
            break;
            
        default:
            break;
    }
}

- (void) videoPlayer:(SCPlayer *)videoPlayer didStartLoadingAtItemTime:(CMTime)itemTime {
	self.loadingView.hidden = NO;
}

- (void) videoPlayer:(SCPlayer *)videoPlayer didEndLoadingAtItemTime:(CMTime)itemTime {
	self.loadingView.hidden = YES;
}

- (void) videoPlayer:(SCPlayer *)videoPlayer didPlay:(Float32)secondsElapsed {
	
}

- (void) videoPlayer:(SCPlayer *)videoPlayer didChangeItem:(AVPlayerItem *)item {
//	self.loadingView.hidden = item == nil;
}

- (void) videoPlayer:(SCPlayer *)videoPlayer didFinishPlaying:(AVPlayerItem *)item {
    
}

- (void) layoutSubviews {
	[super layoutSubviews];
	
	self.playerLayer.frame = self.bounds;
	self.loadingView.frame = self.bounds;
}

- (void) setLoadingView:(UIView *)loadingView {
	if (_loadingView != nil) {
		[_loadingView removeFromSuperview];
	}
	
	_loadingView = loadingView;
	
	if (_loadingView != nil) {
		[self addSubview:_loadingView];
	}
}

@end
