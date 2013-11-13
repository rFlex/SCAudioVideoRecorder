//
//  VRVideoRecorder.m
//  VideoRecorder
//
//  Created by Simon CORSIN on 8/3/13.
//  Copyright (c) 2013 rFlex. All rights reserved.
//

#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
#import <AssetsLibrary/AssetsLibrary.h>
#endif
#import "SCAudioVideoRecorderInternal.h"

#import "NSArray+SCAdditions.h"

#import <ImageIO/ImageIO.h>
// photo dictionary key definitions

NSString * const SCAudioVideoRecorderPhotoMetadataKey = @"SCAudioVideoRecorderPhotoMetadataKey";
NSString * const SCAudioVideoRecorderPhotoJPEGKey = @"SCAudioVideoRecorderPhotoJPEGKey";
NSString * const SCAudioVideoRecorderPhotoImageKey = @"SCAudioVideoRecorderPhotoImageKey";
NSString * const SCAudioVideoRecorderPhotoThumbnailKey = @"SCAudioVideoRecorderPhotoThumbnailKey";

static CGFloat const SCAudioVideoRecorderThumbnailWidth = 160.0f;

////////////////////////////////////////////////////////////
// PRIVATE DEFINITION
/////////////////////

@interface SCAudioVideoRecorder() {
	BOOL recording;
	BOOL shouldWriteToCameraRoll;
	BOOL audioEncoderReady;
	BOOL videoEncoderReady;
	CMTime _playbackStartTime;
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
	UIBackgroundTaskIdentifier _backgroundIdentifier;
#endif
}

@property (strong, nonatomic) AVCaptureVideoDataOutput * videoOutput;
@property (strong, nonatomic) AVCaptureAudioDataOutput * audioOutput;
@property (strong, nonatomic) AVCaptureStillImageOutput *stillImageOutput;
@property (strong, nonatomic) SCVideoEncoder * videoEncoder;
@property (strong, nonatomic) SCAudioEncoder * audioEncoder;
@property (strong, nonatomic) NSURL * outputFileUrl;
@property (strong, nonatomic) AVPlayer * playbackPlayer;
@property (assign, nonatomic) CMTime currentRecordingTime;

@end

////////////////////////////////////////////////////////////
// IMPLEMENTATION
/////////////////////

@implementation SCAudioVideoRecorder

@synthesize delegate;
@synthesize videoOutput;
@synthesize audioOutput;
@synthesize outputFileUrl;
@synthesize audioEncoder;
@synthesize videoEncoder;
@synthesize dispatchDelegateMessagesOnMainQueue;
@synthesize outputFileType;
@synthesize playbackAsset;
@synthesize playbackPlayer;
@synthesize recordingDurationLimit;

- (id) init {
	self = [super init];
	
	if (self) {
		self.outputFileType = AVFileTypeMPEG4;
		self.recordingDurationLimit = kCMTimePositiveInfinity;
		
		self.dispatch_queue = dispatch_queue_create("SCVideoRecorder", nil);
		
		audioEncoderReady = NO;
		videoEncoderReady = NO;
		self.audioEncoder = [[SCAudioEncoder alloc] initWithAudioVideoRecorder:self];
		self.videoEncoder = [[SCVideoEncoder alloc] initWithAudioVideoRecorder:self];
		self.audioEncoder.delegate = self;
		self.videoEncoder.delegate = self;
		recording = NO;
		
		self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
		[self.videoOutput setSampleBufferDelegate:self.videoEncoder queue:self.dispatch_queue];
		
		self.audioOutput = [[AVCaptureAudioDataOutput alloc] init];
		[self.audioOutput setSampleBufferDelegate:self.audioEncoder queue:self.dispatch_queue];
        
        // setup photo settings
        NSDictionary *photoSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
                                       AVVideoCodecJPEG, AVVideoCodecKey,
                                       nil];
        self.stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        [self.stillImageOutput setOutputSettings:photoSettings];
		
		self.lastFrameTimeBeforePause = CMTimeMake(0, 1);
		self.dispatchDelegateMessagesOnMainQueue = YES;
		self.enableSound = YES;
		self.enableVideo = YES;
		_playbackStartTime = kCMTimeZero;
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
		_backgroundIdentifier = UIBackgroundTaskInvalid;
#endif
	}
	return self;
}

- (void)dealloc {
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.stillImageOutput = nil;
    
    self.videoEncoder = nil;
    self.audioEncoder = nil;
    
    self.outputFileUrl = nil;
    
    self.playbackAsset = nil;
    
    self.outputFileType = nil;
    
    self.dispatch_queue = nil;
    
    self.assetWriter = nil;
}

// Hack to force ARC to not release an object in a code block
- (void) pleaseDontReleaseObject:(id)object {
	
}

//
// Video Recorder methods
//

- (void) prepareRecordingAtCameraRoll:(NSError **)error {
	[self prepareRecordingOnTempDir:error];
	shouldWriteToCameraRoll = YES;
}

- (NSURL*) prepareRecordingOnTempDir:(NSError **)error {
	long timeInterval =  (long)[[NSDate date] timeIntervalSince1970];
	NSURL * fileUrl = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@%ld%@", NSTemporaryDirectory(), timeInterval, @"SCVideo.mp4"]];
    
	NSError * recordError = nil;
	[self prepareRecordingAtUrl:fileUrl error:&recordError];
    
	if (recordError != nil) {
		if (error != nil) {
			*error = recordError;
		}
		[self removeFile:fileUrl];
		fileUrl = nil;
        
	}
    
	return fileUrl;
}


- (void) prepareRecordingAtUrl:(NSURL *)fileUrl error:(NSError **)error {
	if (fileUrl == nil) {
		[NSException raise:@"Invalid argument" format:@"FileUrl must be not nil"];
	}
	   
	dispatch_sync(self.dispatch_queue, ^{
		[self resetInternal];
		[self startBackgroundTask];
		
		shouldWriteToCameraRoll = NO;
		self.currentTimeOffset = CMTimeMake(0, 1);
		
		NSError * assetError;
		
		AVAssetWriter * writer = [[AVAssetWriter alloc] initWithURL:fileUrl fileType:self.outputFileType error:&assetError];
		
		if (assetError == nil) {
			self.assetWriter = writer;
			self.outputFileUrl = fileUrl;
			
			if (error != nil) {
				*error = nil;
			}
		} else {
			if (error != nil) {
				*error = assetError;
			}
		}
	});
	if (self.playbackAsset != nil) {
		self.playbackPlayer = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:self.playbackAsset]];
		[self.playbackPlayer seekToTime:self.playbackStartTime];
	}
}

- (void) removeFile:(NSURL *)fileURL {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *filePath = [fileURL path];
	if ([fileManager fileExistsAtPath:filePath]) {
		NSError *error;
		[fileManager removeItemAtPath:filePath error:&error];
	}
}

- (void) finalizeAudioMixForUrl:(NSURL*)fileUrl  withCompletionBlock:(void(^)())completionBlock {
	if (self.playbackAsset != nil) {
		// Move the file to a tmp one
		NSURL * oldUrl = [[fileUrl URLByDeletingPathExtension] URLByAppendingPathExtension:@"old.mov"];
		[[NSFileManager defaultManager] moveItemAtURL:fileUrl toURL:oldUrl error:nil];
		
		AVMutableComposition * composition = [[AVMutableComposition alloc] init];
		
		AVMutableCompositionTrack * audioTrackComposition = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
		
		AVMutableCompositionTrack * videoTrackComposition = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
		
		AVURLAsset * fileAsset = [AVURLAsset URLAssetWithURL:oldUrl options:nil];

		NSArray * videoTracks = [fileAsset tracksWithMediaType:AVMediaTypeVideo];
		
		CMTime duration = ((AVAssetTrack*)[videoTracks objectAtIndex:0]).timeRange.duration;
		
		// We check if the recorded time if more than the limit
		if (CMTIME_COMPARE_INLINE(duration, >, self.recordingDurationLimit)) {
			duration = self.recordingDurationLimit;
		}
		
		for (AVAssetTrack * track in [self.playbackAsset tracksWithMediaType:AVMediaTypeAudio]) {
			[audioTrackComposition insertTimeRange:CMTimeRangeMake(self.playbackStartTime, duration) ofTrack:track atTime:kCMTimeZero error:nil];
		}
		
		for (AVAssetTrack * track in [fileAsset tracksWithMediaType:AVMediaTypeAudio]) {
			[audioTrackComposition insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:track atTime:kCMTimeZero error:nil];
		}
		
		for (AVAssetTrack * track in videoTracks) {
			[videoTrackComposition insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:track atTime:kCMTimeZero error:nil];
		}
		videoTrackComposition.preferredTransform = self.videoEncoder.outputAffineTransform;
		
		AVAssetExportSession * exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
		exportSession.outputFileType = self.outputFileType;
		exportSession.shouldOptimizeForNetworkUse = YES;
		exportSession.outputURL = fileUrl;
		
		
		[exportSession exportAsynchronouslyWithCompletionHandler:^ {
			[self pleaseDontReleaseObject:exportSession];
			
			[self removeFile:oldUrl];
			completionBlock();
		}];
	} else {
		completionBlock();
	}
}

- (void) assetWriterFinished:(NSURL*)fileUrl {
	self.assetWriter = nil;
	self.outputFileUrl = nil;
	[self.audioEncoder reset];
	[self.videoEncoder reset];
	
	[self finalizeAudioMixForUrl:fileUrl withCompletionBlock:^ {
		if (shouldWriteToCameraRoll) {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE			
			ALAssetsLibrary * library = [[ALAssetsLibrary alloc] init];
			[library writeVideoAtPathToSavedPhotosAlbum:fileUrl completionBlock:^(NSURL *assetUrl, NSError * error) {
				[self pleaseDontReleaseObject:library];
				
				if (error != nil) {
					NSLog(@"Error: %@", error);
				}
				
				[self removeFile:fileUrl];
				
				[self notifyRecordFinishedAtUrl:assetUrl withError:error];
			}];
#endif
		} else {
			[self notifyRecordFinishedAtUrl:fileUrl withError:nil];
		}
	}];
}

- (void) finishWriter:(NSURL*)fileUrl {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
    [self.assetWriter finishWritingWithCompletionHandler:^ {
        [self assetWriterFinished:fileUrl];
    }];
#else
    [self.assetWriter finishWriting];
    [self assetWriterFinished:fileUrl];
#endif
}

- (void) notifyRecordFinishedAtUrl:(NSURL*)url withError:(NSError*)error {
	[self dispatchBlockOnAskedQueue:^{
		if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:didFinishRecordingAtUrl:error:)]) {
			[self.delegate audioVideoRecorder:self didFinishRecordingAtUrl:url error:error];
		}
	}];
}

- (void) startBackgroundTask {
	[self stopBackgroundTask];
	
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
	_backgroundIdentifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
		[self stopBackgroundTask];
	}];
#endif
}

- (void) stopBackgroundTask {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
	if (_backgroundIdentifier != UIBackgroundTaskInvalid) {
		[[UIApplication sharedApplication] endBackgroundTask:_backgroundIdentifier];
		_backgroundIdentifier = UIBackgroundTaskInvalid;
	}
#endif
}

// Photo

#if TARGET_IPHONE_SIMULATOR || TARGET_OS_IPHONE
- (UIImage *)_uiimageFromJPEGData:(NSData *)jpegData
{
	return [UIImage imageWithData:jpegData];
}

- (UIImage *)_thumbnailJPEGData:(NSData *)jpegData
{
    CGImageRef thumbnailCGImage = NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpegData);
    
    if (provider) {
        CGImageSourceRef imageSource = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (imageSource) {
            if (CGImageSourceGetCount(imageSource) > 0) {
                NSMutableDictionary *options = [[NSMutableDictionary alloc] initWithCapacity:3];
                [options setObject:[NSNumber numberWithBool:YES] forKey:(id)kCGImageSourceCreateThumbnailFromImageAlways];
                [options setObject:[NSNumber numberWithFloat:SCAudioVideoRecorderThumbnailWidth] forKey:(id)kCGImageSourceThumbnailMaxPixelSize];
                [options setObject:[NSNumber numberWithBool:NO] forKey:(id)kCGImageSourceCreateThumbnailWithTransform];
                thumbnailCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
            }
            CFRelease(imageSource);
        }
        CGDataProviderRelease(provider);
    }
    
    UIImage *thumbnail = nil;
    if (thumbnailCGImage) {
        thumbnail = [[UIImage alloc] initWithCGImage:thumbnailCGImage scale:1 orientation:UIImageOrientationUp];
        CGImageRelease(thumbnailCGImage);
    }
    return thumbnail;
}

- (void) capturePhoto {
    if (self.stillImageOutput) {
        AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
        [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:
         ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
             
             if (!imageDataSampleBuffer) {
                 NSLog(@"failed to obtain image data sample buffer");
                 // TODO: return delegate error
                 return;
             }
             
             if (error) {
				 [self dispatchBlockOnAskedQueue:^{
					 if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:capturedPhoto:error:)]) {
						 [self.delegate audioVideoRecorder:self capturedPhoto:nil error:error];
					 }
				 }];
				 return;
             }
             
             NSMutableDictionary *photoDict = [[NSMutableDictionary alloc] init];
             NSDictionary *metadata = nil;
             
             // add photo metadata (ie EXIF: Aperture, Brightness, Exposure, FocalLength, etc)
             metadata = (__bridge NSDictionary *)CMCopyDictionaryOfAttachments(kCFAllocatorDefault, imageDataSampleBuffer, kCMAttachmentMode_ShouldPropagate);
             if (metadata) {
                 [photoDict setObject:metadata forKey:SCAudioVideoRecorderPhotoMetadataKey];
                 CFRelease((__bridge CFTypeRef)(metadata));
             } else {
                 NSLog(@"failed to generate metadata for photo");
             }
             
             // add JPEG and image data
             NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
             if (jpegData) {
                 // add JPEG
                 [photoDict setObject:jpegData forKey:SCAudioVideoRecorderPhotoJPEGKey];
                 
                 // add image
                 UIImage *image = [self _uiimageFromJPEGData:jpegData];
                 if (image) {
                     [photoDict setObject:image forKey:SCAudioVideoRecorderPhotoImageKey];
                 } else {
                     NSLog(@"failed to create image from JPEG");
                     // TODO: return delegate on error
                 }
                 
                 // add thumbnail
                 UIImage *thumbnail = [self _thumbnailJPEGData:jpegData];
                 if (thumbnail) {
                     [photoDict setObject:thumbnail forKey:SCAudioVideoRecorderPhotoThumbnailKey];
                 } else {
                     NSLog(@"failed to create a thumnbail");
                     // TODO: return delegate on error
                 }
                 
             } else {
                 NSLog(@"failed to create jpeg still image data");
                 // TODO: return delegate on error
             }
             
			 [self dispatchBlockOnAskedQueue:^{
				 if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:capturedPhoto:error:)]) {
					 [self.delegate audioVideoRecorder:self capturedPhoto:photoDict error:error];
				 }
			 }];
         }];
    }
}
#endif

- (void) stop {
	[self pause];
	[self stopBackgroundTask];
	
	if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:willFinishRecordingAtTime:)]) {
		[self.delegate audioVideoRecorder:self willFinishRecordingAtTime:self.currentRecordingTime];
	}
    
	dispatch_async(self.dispatch_queue, ^ {
		if (self.assetWriter == nil) {
			[self notifyRecordFinishedAtUrl:nil withError:[SCAudioVideoRecorder createError:@"Recording must be started before calling stopRecording"]];
		} else {
			NSURL * fileUrl = self.outputFileUrl;
			NSError * error = self.assetWriter.error;
			
			switch (self.assetWriter.status) {
				case AVAssetWriterStatusWriting:
					[self finishWriter:fileUrl];
					break;
				case AVAssetWriterStatusCompleted:
					[self assetWriterFinished:fileUrl];
					break;
				case AVAssetWriterStatusFailed:
					[self resetInternal];
					[self notifyRecordFinishedAtUrl:nil withError:error];
					break;
				case AVAssetWriterStatusCancelled:
					[self resetInternal];
					[self notifyRecordFinishedAtUrl:nil withError:[SCAudioVideoRecorder createError:@"Writer cancelled"]];
					break;
				case AVAssetWriterStatusUnknown:
					[self resetInternal];
					[self notifyRecordFinishedAtUrl:nil withError:[SCAudioVideoRecorder createError:@"Writer status unknown"]];
					break;
			}
		}
    });
}

- (void) pause {
	[self.playbackPlayer pause];
	recording = NO;
	self.lastFrameTimeBeforePause = CMTimeMake(1, 24);
}

- (void) record {
	if (![self isPrepared]) {
		[NSException raise:@"Recording not previously started" format:@"Recording should be started using startRecording before trying to resume it"];
	}
	
	[self.playbackPlayer play];
	dispatch_async(self.dispatch_queue, ^ {
		self.shouldComputeOffset = YES;
		recording = YES;
    });
}

- (void) cancel {
	dispatch_sync(self.dispatch_queue, ^{
		[self resetInternal];
    });
}

- (void) resetInternal {
	[self stopBackgroundTask];
	AVAssetWriter * writer = self.assetWriter;
	NSURL * fileUrl = self.outputFileUrl;
	
	audioEncoderReady = NO;
	videoEncoderReady = NO;
	
	self.outputFileUrl = nil;
	self.assetWriter = nil;
	self.playbackPlayer = nil;

	recording = NO;
    
	[self.audioEncoder reset];
	[self.videoEncoder reset];
    
	if (writer != nil) {
		if (writer.status == AVAssetWriterStatusWriting) {
			[writer cancelWriting];
		}
		if (fileUrl != nil) {
			[self removeFile:fileUrl];
		}
	}
}

//
// DataEncoder Delegate implementation
//

- (void) dataEncoder:(SCDataEncoder *)dataEncoder didEncodeFrame:(CMTime)frameTime {
    [self dispatchBlockOnAskedQueue:^ {
		self.currentRecordingTime = frameTime;
		
        if (dataEncoder == self.audioEncoder) {
            if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:didRecordAudioSample:)]) {
                [self.delegate audioVideoRecorder:self didRecordAudioSample:frameTime];
            }
        } else if (dataEncoder == self.videoEncoder) {
            if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:didRecordVideoFrame:)]) {
                [self.delegate audioVideoRecorder:self didRecordVideoFrame:frameTime];
            }
        }
		if (CMTIME_COMPARE_INLINE(frameTime, >=, self.recordingDurationLimit)) {
			[self stop];
		}
    }];
}

- (void) dataEncoder:(SCDataEncoder *)dataEncoder didFailToInitializeEncoder:(NSError *)error {
    [self dispatchBlockOnAskedQueue: ^ {
        if (dataEncoder == self.audioEncoder) {
            if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:didFailToInitializeAudioEncoder:)]) {
                [self.delegate audioVideoRecorder:self didFailToInitializeAudioEncoder:error];
            }
        } else if (dataEncoder == self.videoEncoder) {
            if ([self.delegate respondsToSelector:@selector(audioVideoRecorder:didFailToInitializeVideoEncoder:)]) {
                [self.delegate audioVideoRecorder:self didFailToInitializeVideoEncoder:error];
            }
        }
    }];
}

//
// Misc methods
//

- (void) dispatchBlockOnAskedQueue:(void(^)())block {
	if (self.dispatchDelegateMessagesOnMainQueue) {
		dispatch_async(dispatch_get_main_queue(), block);
	} else {
		block();
	}
}

+ (NSError*) createError:(NSString*)name {
	return [NSError errorWithDomain:@"SCAudioVideoRecorder" code:500 userInfo:[NSDictionary dictionaryWithObject:name forKey:NSLocalizedDescriptionKey]];
}

- (void) prepareWriterAtSourceTime:(CMTime)sourceTime fromEncoder:(SCDataEncoder*)encoder {
    // Set an encoder as ready if it's the caller or if it's not enabled
    audioEncoderReady |= (encoder == self.audioEncoder) | !self.audioEncoder.enabled;
    videoEncoderReady |= (encoder == self.videoEncoder) | !self.videoEncoder.enabled;
    
    // We only start the writing when both encoder are ready
    if (audioEncoderReady && videoEncoderReady) {
        if (self.assetWriter.status == AVAssetWriterStatusUnknown) {
            if ([self.assetWriter startWriting]) {
                [self.assetWriter startSessionAtSourceTime:sourceTime];
            }
            self.startedTime = sourceTime;
        }
    }
}

//
// Getters/Setters
//

- (BOOL) isPrepared {
    return self.assetWriter != nil;
}

- (BOOL) isRecording {
    return recording;
}

- (void) setEnableSound:(BOOL)enableSound {
    self.audioEncoder.enabled = enableSound;
}

- (BOOL) enableSound {
    return self.audioEncoder.enabled;
}

- (void) setEnableVideo:(BOOL)enableVideo {
    self.videoEncoder.enabled = enableVideo;
}

- (BOOL) enableVideo {
    return self.videoEncoder.enabled;
}

- (CMTime) playbackStartTime {
	return _playbackStartTime;
}

- (void) setPlaybackStartTime:(CMTime)startTime {
	_playbackStartTime = startTime;
	[self.playbackPlayer seekToTime:startTime];
}

@end
