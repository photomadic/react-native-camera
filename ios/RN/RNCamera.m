#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNFileSystem.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>
#import <Vision/Vision.h>

@interface RNCamera ()

@property (nonatomic, weak) RCTBridge *bridge;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;

@end

@implementation RNCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithBridge:(RCTBridge *)bridge
{
    if ((self = [super init])) {
        self.bridge = bridge;
        self.session = [AVCaptureSession new];
        self.sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
        self.faceDetectorManager = [self createFaceDetectorManager];
#if !(TARGET_IPHONE_SIMULATOR)
        self.previewLayer =
        [AVCaptureVideoPreviewLayer layerWithSession:self.session];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
        self.overlayLayer = [CALayer layer];
        self.paused = NO;
        [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
        [self initializeCaptureSessionInput];
        [self startSession];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
        self.autoFocus = -1;
    }
    return self;
}

- (UIColor *)backgroundColor
{
    return [UIColor blackColor];
}

- (void)onReady:(NSDictionary *)event
{
    if (_onCameraReady) {
        _onCameraReady(nil);
    }
}

- (void)onMountingError:(NSDictionary *)event
{
    if (_onMountError) {
        _onMountError(event);
    }
}

- (void)onCodeRead:(NSDictionary *)event
{
    if (_onBarCodeRead) {
        _onBarCodeRead(event);
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.previewLayer.frame = self.bounds;
    [self.layer insertSublayer:self.previewLayer atIndex:0];

    self.overlayLayer.frame = self.bounds;
    [self.layer insertSublayer:self.overlayLayer atIndex:1];
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    [self insertSubview:view atIndex:atIndex + 1];
    [super insertReactSubview:view atIndex:atIndex];
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    [subview removeFromSuperview];
    [super removeReactSubview:subview];
    return;
}

- (void)removeFromSuperview
{
    [self stopSession];
    [super removeFromSuperview];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

-(void)updateType
{
    dispatch_async(self.sessionQueue, ^{
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
    });
}

- (void)updateFlashMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.flashMode == RNCameraFlashModeTorch) {
        if (![device hasTorch])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                [device setFlashMode:AVCaptureFlashModeOff];
                [device setTorchMode:AVCaptureTorchModeOn];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    } else {
        if (![device hasFlash])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }
                [device setFlashMode:self.flashMode];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isFocusModeSupported:self.autoFocus]) {
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:self.autoFocus];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateExposureMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        if ([device lockForConfiguration:&error]) {
            [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff || device.position == RNCameraTypeFront) {
        return;
    }

    if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
        RCTLog(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
        return;
    }

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    __weak __typeof__(device) weakDevice = device;
    [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
    }];
}

- (void)updateZoom {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;

    [device unlockForConfiguration];
}

- (void)updateWhiteBalance
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if (self.whiteBalance == RNCameraWhiteBalanceAuto) {
        [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        [device unlockForConfiguration];
    } else {
        AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
            .temperature = [RNCameraUtils temperatureForWhiteBalance:self.whiteBalance],
            .tint = 0,
        };
        AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
        __weak __typeof__(device) weakDevice = device;
        if ([device lockForConfiguration:&error]) {
            [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
                [weakDevice unlockForConfiguration];
            }];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
- (void)updateFaceDetecting:(id)faceDetecting
{
    [_faceDetectorManager setIsEnabled:faceDetecting];
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
    [_faceDetectorManager setMode:requestedMode];
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
    [_faceDetectorManager setLandmarksDetected:requestedLandmarks];
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
    [_faceDetectorManager setClassificationsDetected:requestedClassifications];
}
#endif

- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:[RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if (imageSampleBuffer && !error) {
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];

            UIImage *takenImage = [UIImage imageWithData:imageData];

            CGRect frame = [_previewLayer metadataOutputRectOfInterestForRect:self.frame];
            CGImageRef takenCGImage = takenImage.CGImage;
            size_t width = CGImageGetWidth(takenCGImage);
            size_t height = CGImageGetHeight(takenCGImage);
            CGRect cropRect = CGRectMake(frame.origin.x * width, frame.origin.y * height, frame.size.width * width, frame.size.height * height);
            takenImage = [RNImageUtils cropImage:takenImage toRect:cropRect];

            if ([options[@"mirrorImage"] boolValue]) {
                takenImage = [RNImageUtils mirrorImage:takenImage];
            }
            if ([options[@"forceUpOrientation"] boolValue]) {
                takenImage = [RNImageUtils forceUpOrientation:takenImage];
            }

            if ([options[@"width"] integerValue]) {
                takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
            }

            // If an overlay image is present, composite the image over the top
            // of the original photo maintaining the viewport aspect ratio.
            if (self.overlayImage) {
                takenImage = [RNImageUtils overlayImage:takenImage withImage:self.overlayImage];
            }

            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            float quality = [options[@"quality"] floatValue];
            NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
            response[@"width"] = @(takenImage.size.width);
            response[@"height"] = @(takenImage.size.height);

            if ([options[@"base64"] boolValue]) {
                response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
            }

            if ([options[@"exif"] boolValue]) {
                int imageRotation;
                switch (takenImage.imageOrientation) {
                    case UIImageOrientationLeft:
                    case UIImageOrientationRightMirrored:
                        imageRotation = 90;
                        break;
                    case UIImageOrientationRight:
                    case UIImageOrientationLeftMirrored:
                        imageRotation = -90;
                        break;
                    case UIImageOrientationDown:
                    case UIImageOrientationDownMirrored:
                        imageRotation = 180;
                        break;
                    case UIImageOrientationUpMirrored:
                    default:
                        imageRotation = 0;
                        break;
                }
                [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
            }

            resolve(response);
        } else {
            reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
        }
    }];
}

- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    [self setupVideoStreamCapture];

    if (_videoRecordedResolve != nil || _videoRecordedReject != nil) {
      return;
    }

    if (options[@"quality"]) {
        [self updateSessionPreset:[RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]]];
    }

    if (options[@"inputFps"] && options[@"outputFps"]) {
        self.animationInputFps = [options[@"inputFps"] integerValue];
        self.animationOutputFps = [options[@"outputFps"] integerValue];
        self.animationOutputSize = CGSizeMake([options[@"outputWidth"] integerValue], [options[@"outputHeight"] integerValue]);
    }

    if ([options[@"mirrorImage"] boolValue]) {
        self.mirrorImage = [options[@"mirrorImage"] boolValue];
    }

    if (options[@"maxDuration"]) {
        self.maxDuration = [options[@"maxDuration"] floatValue];
    }

    [self updateSessionAudioIsMuted:!!options[@"mute"]];

    // Set flag that notifies 'didOutputSampleBuffer' delegate method to initialize writer with buffer presentation timestamp
    self.canAppendBuffer = YES;
    self.videoRecordedResolve = resolve;
    self.videoRecordedReject = reject;

    dispatch_async(self.sessionQueue, ^{
        [self updateFlashMode];
    });
}

- (void)stopAssetWriter {
    self.canAppendBuffer = NO;
    [self.writerInput markAsFinished];
    [self.videoWriter finishWritingWithCompletionHandler:^{
        if (self.videoWriter.status != AVAssetWriterStatusFailed) {
            [self processVideoToAnimation:self.videoWriter.outputURL];
        } else if (self.videoRecordedReject != nil) {
            self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", nil);
        }

        [self.session removeOutput:self.videoOutput];
        self.videoOutput = nil;
        self.writerInput = nil;
        self.videoWriter = nil;
    }];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    [self findPrimaryFace:sampleBuffer];

    if (self.canAppendBuffer) {
        if (self.videoWriter.status != AVAssetWriterStatusWriting) {
            [self.videoWriter startWriting];
            [self.videoWriter startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.timer = [NSTimer scheduledTimerWithTimeInterval:self.maxDuration target:self selector:@selector(stopAssetWriter) userInfo:nil repeats:NO];
            });
        }
        [self.writerInput appendSampleBuffer:sampleBuffer];
    }
}

-(void)findPrimaryFace:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CIImage *orientedImage = [image imageByApplyingCGOrientation:kCGImagePropertyOrientationUpMirrored];

    VNDetectFaceRectanglesRequest *faceDetectionReq = [VNDetectFaceRectanglesRequest new];
    NSDictionary *d = [[NSDictionary alloc] init];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:orientedImage options:d];
    [handler performRequests:@[faceDetectionReq] error:nil];

    VNFaceObservation *primaryFace;
    CGPoint primaryFaceCenter;
    float primaryFaceSize;

    for(VNFaceObservation *observation in faceDetectionReq.results){
        if(observation){
            float size = observation.boundingBox.size.height * observation.boundingBox.size.width;
            if (!primaryFace || size > primaryFaceSize) {
                primaryFace = observation;
                primaryFaceCenter = CGPointMake(CGRectGetMidX(observation.boundingBox), CGRectGetMidY(observation.boundingBox));
                primaryFaceSize = size;
            }
        }
    }

    if ([faceDetectionReq.results count]) {
        [self setExposure:primaryFaceCenter];
    }
}

- (void)resetExposureTimeout;
{
    self.exposureTimeout = NO;
}

- (void)setExposure:(CGPoint) point;
{
    if (self.exposureTimeout) {
        return;
    }
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    [device lockForConfiguration:nil];
    CGPoint scaledPoint = CGPointMake(point.x * self.layer.bounds.size.width, (1-point.y) * self.layer.bounds.size.height);
    CGPoint devicePoint = [self.previewLayer captureDevicePointOfInterestForPoint:scaledPoint];
    [device setExposurePointOfInterest:devicePoint];
    if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
    {
        [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
    }
    [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    [device unlockForConfiguration];

    self.exposureTimeout = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.exposureTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(resetExposureTimeout) userInfo:nil repeats:NO];
    });
}


- (void)startSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    //    NSDictionary *cameraPermissions = [EXCameraPermissionRequester permissions];
    //    if (![cameraPermissions[@"status"] isEqualToString:@"granted"]) {
    //        [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    //        return;
    //    }
    self.exposureTimeout = NO;
    self.canAppendBuffer = NO;

    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }

        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([self.session canAddOutput:stillImageOutput]) {
            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
            [self.session addOutput:stillImageOutput];
            [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
            self.stillImageOutput = stillImageOutput;
        }

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#else
        // If AVCaptureVideoDataOutput is not required because of Google Vision
        // (see comment in -record), we go ahead and add the AVCaptureMovieFileOutput
        // to avoid an exposure rack on some devices that can cause the first few
        // frames of the recorded output to be underexposed.
        [self setupVideoStreamCapture];
#endif
        [self setupOrDisableBarcodeScanner];

        __weak RNCamera *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:
         [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
            RNCamera *strongSelf = weakSelf;
            dispatch_async(strongSelf.sessionQueue, ^{
                // Manually restarting the session since it must
                // have been stopped due to an error.
                [strongSelf.session startRunning];
                [strongSelf onReady:nil];
            });
        }]];

        [self.session startRunning];
        [self onReady:nil];
    });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    dispatch_async(self.sessionQueue, ^{
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        [self.previewLayer removeFromSuperlayer];
        [self.session commitConfiguration];
        [self.session stopRunning];
        for (AVCaptureInput *input in self.session.inputs) {
            [self.session removeInput:input];
        }

        for (AVCaptureOutput *output in self.session.outputs) {
            [self.session removeOutput:output];
        }
    });
}

- (void)initializeCaptureSessionInput
{
    if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
        return;
    }
    __block UIInterfaceOrientation interfaceOrientation;

    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }

    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        NSError *error = nil;
        AVCaptureDevice *captureDevice = [RNCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera];
        AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];

        if (error || captureDeviceInput == nil) {
            RCTLog(@"%s: %@", __func__, error);
            return;
        }

        [self.session removeInput:self.videoCaptureDeviceInput];
        if ([self.session canAddInput:captureDeviceInput]) {
            [self.session addInput:captureDeviceInput];

            self.videoCaptureDeviceInput = captureDeviceInput;
            [self updateFlashMode];
            [self updateZoom];
            [self updateFocusMode];
            [self updateFocusDepth];
            [self updateWhiteBalance];
            [self updateExposureMode];
            [self.previewLayer.connection setVideoOrientation:orientation];
            [self _updateMetadataObjectsToRecognize];
        }

        [self.session commitConfiguration];
    });
}

#pragma mark - internal

- (void)updateSessionPreset:(NSString *)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
    if (preset) {
        dispatch_async(self.sessionQueue, ^{
            [self.session beginConfiguration];
            if ([self.session canSetSessionPreset:preset]) {
                self.session.sessionPreset = preset;
            }
            [self.session commitConfiguration];
        });
    }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        for (AVCaptureDeviceInput* input in [self.session inputs]) {
            if ([input.device hasMediaType:AVMediaTypeAudio]) {
                if (isMuted) {
                    [self.session removeInput:input];
                }
                [self.session commitConfiguration];
                return;
            }
        }

        if (!isMuted) {
            NSError *error = nil;

            AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];

            if (error || audioDeviceInput == nil) {
                RCTLogWarn(@"%s: %@", __func__, error);
                return;
            }

            if ([self.session canAddInput:audioDeviceInput]) {
                [self.session addInput:audioDeviceInput];
            }
        }

        [self.session commitConfiguration];
    });
}

- (void)bridgeDidForeground:(NSNotification *)notification
{

    if (![self.session isRunning] && [self isSessionPaused]) {
        self.paused = NO;
        dispatch_async( self.sessionQueue, ^{
            [self.session startRunning];
        });
    }
}

- (void)bridgeDidBackground:(NSNotification *)notification
{
    if ([self.session isRunning] && ![self isSessionPaused]) {
        self.paused = YES;
        dispatch_async( self.sessionQueue, ^{
            [self.session stopRunning];
        });
    }
}

- (void)orientationChanged:(NSNotification *)notification
{
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation
{
    __weak typeof(self) weakSelf = self;
    AVCaptureVideoOrientation videoOrientation = [RNCameraUtils videoOrientationForInterfaceOrientation:orientation];
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
            [strongSelf.previewLayer.connection setVideoOrientation:videoOrientation];
        }
    });
}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableBarcodeScanner
{
    [self _setupOrDisableMetadataOutput];
    [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
    if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
        AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.session canAddOutput:metadataOutput]) {
            [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
            [self.session addOutput:metadataOutput];
            self.metadataOutput = metadataOutput;
        }
    } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
        [self.session removeOutput:_metadataOutput];
        _metadataOutput = nil;
    }
}

- (void)_updateMetadataObjectsToRecognize
{
    if (_metadataOutput == nil) {
        return;
    }

    NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = [[NSArray alloc] init];
    NSArray<AVMetadataObjectType> *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
    NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;

    for(AVMetadataObjectType objectType in requestedObjectTypes) {
        if ([availableObjectTypes containsObject:objectType]) {
            availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
        }
    }

    [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    for(AVMetadataObject *metadata in metadataObjects) {
        if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
            for (id barcodeType in self.barCodeTypes) {
                if ([metadata.type isEqualToString:barcodeType]) {
                    AVMetadataMachineReadableCodeObject *transformed = (AVMetadataMachineReadableCodeObject *)[_previewLayer transformedMetadataObjectForMetadataObject:metadata];
                    NSDictionary *event = @{
                                            @"type" : codeMetadata.type,
                                            @"data" : codeMetadata.stringValue,
                                            @"bounds": @{
                                                @"origin": @{
                                                    @"x": [NSString stringWithFormat:@"%f", transformed.bounds.origin.x],
                                                    @"y": [NSString stringWithFormat:@"%f", transformed.bounds.origin.y]
                                                },
                                                @"size": @{
                                                    @"height": [NSString stringWithFormat:@"%f", transformed.bounds.size.height],
                                                    @"width": [NSString stringWithFormat:@"%f", transformed.bounds.size.width]
                                                }
                                            }
                                            };

                    [self onCodeRead:event];
                }
            }
        }
    }
}

# pragma mark - AVAssetWriter

- (void)setupVideoStreamCapture
{
    NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".mov"];
    NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];

    NSError *error = nil;
    self.videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
    self.writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil];
    [self.videoWriter addInput:self.writerInput];

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [self.videoOutput setSampleBufferDelegate:self queue:self.sessionQueue];
    if ( [self.session canAddOutput:self.videoOutput] ){
        [self.session addOutput:self.videoOutput];
    }

    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    dispatch_async(dispatch_get_main_queue(), ^{
        [connection setVideoOrientation:[RNCameraUtils videoOrientationForInterfaceOrientation:[[UIApplication sharedApplication] statusBarOrientation]]];
    });
}

# pragma mark - Animation creator

- (void)processVideoToAnimation:(NSURL *)outputFileURL {
    AVURLAsset* videoAsAsset = [AVURLAsset URLAssetWithURL:outputFileURL options:nil];
    AVAssetTrack* videoTrack = [[videoAsAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];

    float videoWidth;
    float videoHeight;

    CGSize videoSize = [videoTrack naturalSize];
    CGAffineTransform txf = [videoTrack preferredTransform];

    if ((txf.tx == videoSize.width && txf.ty == videoSize.height) || (txf.tx == 0 && txf.ty == 0)) {
        // Video recorded in landscape orientation
        videoWidth = videoSize.width;
        videoHeight = videoSize.height;
    } else {
        // Video recorded in portrait orientation, so have to swap reported width/height
        videoWidth = videoSize.height;
        videoHeight = videoSize.width;
    }

    // The video is recorded at the full native FPS of the camera so that
    // there is no motion blur due to the longer exposure. Because of this,
    // we need to essentially delete frames to arrive at the target FPS for
    // the animation.
    double lengthInSeconds = CMTimeGetSeconds(videoAsAsset.duration);
    int64_t framesNeeded = lengthInSeconds * _animationInputFps;
    double step = lengthInSeconds / framesNeeded;

    NSMutableArray *framesToKeep = [NSMutableArray arrayWithCapacity:framesNeeded];
    NSMutableArray *animatedFrames = [NSMutableArray arrayWithCapacity:framesNeeded * 2];

    for (int i = 0; i < framesNeeded; i++) {
        CMTime time = CMTimeMakeWithSeconds(i * step, videoAsAsset.duration.timescale);
        [framesToKeep addObject: [NSValue valueWithCMTime:time]];
    }

    AVAssetImageGenerator *frameGenerator = [AVAssetImageGenerator assetImageGeneratorWithAsset:videoAsAsset];
    frameGenerator.appliesPreferredTrackTransform = true;
    frameGenerator.apertureMode = AVAssetImageGeneratorApertureModeCleanAperture;
    frameGenerator.requestedTimeToleranceBefore = kCMTimeZero;
    frameGenerator.requestedTimeToleranceAfter = kCMTimeZero;
    [frameGenerator generateCGImagesAsynchronouslyForTimes:framesToKeep completionHandler:^(CMTime requestedTime, CGImageRef  _Nullable image, CMTime actualTime, AVAssetImageGeneratorResult result, NSError * _Nullable error) {
        if (error != nil || image == nil) {
            if (frameGenerator != nil) {
                [frameGenerator cancelAllCGImageGeneration];
            }
            return;
        }

        CGImageRetain(image);
        [animatedFrames addObject:(__bridge id)image];
        CGImageRelease(image);

        // To achieve the back and forth affect we're going for, we simply
        // duplicate the existing frames in reverse. This is more efficient
        // than including the timestamps in the original list of times for
        // the AVAssetImageGenerator to parse.
        if (animatedFrames.count == framesToKeep.count) {
            NSUInteger originalFrameCount = animatedFrames.count - 1;
            for (int i = 0; i < originalFrameCount; i++) {
                NSUInteger reversePosition = originalFrameCount - i;
                [animatedFrames addObject:[animatedFrames objectAtIndex:reversePosition]];
            }

            [self animationFramesToVideo:animatedFrames];
        }
    }];
    return;
}

- (NSDictionary *)animationOutputSettings
{
    return @{
             AVVideoCodecKey: AVVideoCodecH264,
             AVVideoWidthKey: [NSNumber numberWithInt: self.animationOutputSize.width],
             AVVideoHeightKey: [NSNumber numberWithInt: self.animationOutputSize.height],
             AVVideoCompressionPropertiesKey: @{
                     AVVideoAverageBitRateKey: @1000000, // 1Mbps
                     AVVideoMaxKeyFrameIntervalKey: [NSNumber numberWithInt: self.animationOutputFps],
                     AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                     AVVideoAllowFrameReorderingKey: @false,
                     AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                     AVVideoExpectedSourceFrameRateKey: @30,
                     AVVideoAverageNonDroppableFrameRateKey: [NSNumber numberWithInt: self.animationOutputFps],
                     }
             };
}

- (NSDictionary *)animationPixelBufferSettings
{
    return @{
             (id)kCVPixelBufferPixelFormatTypeKey: [NSNumber numberWithUnsignedInt: kCVPixelFormatType_32ARGB],
             (id)kCVPixelBufferWidthKey: [NSNumber numberWithInt: self.animationOutputSize.width],
             (id)kCVPixelBufferHeightKey: [NSNumber numberWithInt: self.animationOutputSize.height],
             };
}

- (void)drawMirrored:(CGContextRef)context width:(double)width
{
    CGAffineTransform transform = CGAffineTransformMakeTranslation(width, 0.0);
    transform = CGAffineTransformScale(transform, -1.0, 1.0);
    CGContextConcatCTM(context, transform);
}

- (void)animationFramesToVideo:(NSMutableArray *)animatedFrames
{
    NSString *outputName = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *fullPath = [NSURL fileURLWithPath: [NSString stringWithFormat:@"%@%@.mp4", NSTemporaryDirectory(), outputName]];

    NSError *writeError;
    AVAssetWriter *videoWriter = [AVAssetWriter assetWriterWithURL:fullPath fileType:AVFileTypeMPEG4 error:&writeError];

    if (writeError != nil) {
        self.videoRecordedReject(RCTErrorUnspecified, nil, RCTErrorWithMessage(writeError.description));
        return;
    }

    videoWriter.shouldOptimizeForNetworkUse = true;

    AVAssetWriterInput *animatedFrameInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.animationOutputSettings];

    AVAssetWriterInputPixelBufferAdaptor *animatedPixelBuffer = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:animatedFrameInput sourcePixelBufferAttributes:self.animationPixelBufferSettings];

    if ([videoWriter canAddInput:animatedFrameInput]) {
        [videoWriter addInput:animatedFrameInput];
    }

    [videoWriter startWriting];
    [videoWriter startSessionAtSourceTime:kCMTimeZero];

    CGFloat videoOffsetHeight = (1280.0 / 720.0) * self.animationOutputSize.width;
    CGFloat videoOffsetY = (videoOffsetHeight - self.animationOutputSize.height) / 2;

    CMTime frameDuration = CMTimeMake(1, self.animationOutputFps);

    Boolean appendSucceeded = true;

    for (int frameCount = 0; frameCount < animatedFrames.count; frameCount++) {
        CGImageRef nextPhoto = (__bridge CGImageRef)[animatedFrames objectAtIndex:frameCount];
        CMTime lastFrameTime = CMTimeMultiply(frameDuration, frameCount);
        CMTime presentationTime = frameCount == 0 ? lastFrameTime : CMTimeAdd(lastFrameTime, frameDuration);

        CVPixelBufferRef pixelBuffer;
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, [animatedPixelBuffer pixelBufferPool], &pixelBuffer);

        while (!animatedFrameInput.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.1];
        }

        if (status == 0) {
            CVPixelBufferRef managedPixelBuffer = pixelBuffer;
            CVPixelBufferLockBaseAddress(managedPixelBuffer, 0);

            CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(managedPixelBuffer), self.animationOutputSize.width, self.animationOutputSize.height, 8, CVPixelBufferGetBytesPerRow(managedPixelBuffer), rgbColorSpace, 2);
            CGContextClearRect(context, CGRectMake(0, 0, self.animationOutputSize.width, _animationOutputSize.height));

            if (self.mirrorImage) {
                [self drawMirrored:context width:_animationOutputSize.width];
            }

            CGContextDrawImage(context, CGRectMake(0, 0 - videoOffsetY, _animationOutputSize.width, videoOffsetHeight), nextPhoto);

            if (self.mirrorImage) {
                [self drawMirrored:context width:_animationOutputSize.width];
            }

            if (self.overlayImage.CGImage != nil) {
                CGContextDrawImage(context, CGRectMake(0, 0, self.animationOutputSize.width, self.animationOutputSize.height), self.overlayImage.CGImage);
            }

            CVPixelBufferUnlockBaseAddress(managedPixelBuffer, 0);

            appendSucceeded = [animatedPixelBuffer appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];

            CGContextRelease(context);
            CGColorSpaceRelease(rgbColorSpace);
            CVPixelBufferRelease(pixelBuffer);
        } else {
            self.videoRecordedReject(RCTErrorUnspecified, nil, RCTErrorWithMessage(@"Failed to allocate pixel buffer"));
            appendSucceeded = false;
        }
    }

    [animatedFrameInput markAsFinished];
    [videoWriter finishWritingWithCompletionHandler:^{
        self.videoRecordedResolve(@{ @"uri": fullPath.absoluteString });

        self.videoRecordedResolve = nil;
        self.videoRecordedReject = nil;
        self.videoCodecType = nil;

        if (self.session.sessionPreset != AVCaptureSessionPresetHigh) {
            [self updateSessionPreset:AVCaptureSessionPresetHigh];
        }
    }];
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
    Class faceDetectorManagerClass = NSClassFromString(@"RNFaceDetectorManager");
    Class faceDetectorManagerStubClass = NSClassFromString(@"RNFaceDetectorManagerStub");

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    if (faceDetectorManagerClass) {
        return [[faceDetectorManagerClass alloc] initWithSessionQueue:_sessionQueue delegate:self];
    } else if (faceDetectorManagerStubClass) {
        return [[faceDetectorManagerStubClass alloc] init];
    }
#endif

    return nil;
}

- (void)onFacesDetected:(NSArray<NSDictionary *> *)faces
{
    if (_onFacesDetected) {
        _onFacesDetected(@{
                           @"type": @"face",
                           @"faces": faces
                           });
    }
}

@end
