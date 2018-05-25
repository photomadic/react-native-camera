#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridge.h>
#import <React/RCTBridgeModule.h>
#import <UIKit/UIKit.h>

#if __has_include("RNFaceDetectorManager.h")
#import "RNFaceDetectorManager.h"
#else
#import "RNFaceDetectorManagerStub.h"
#endif

@class RNCamera;

@interface RNCamera : UIView <AVCaptureMetadataOutputObjectsDelegate, RNFaceDetectorDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, strong) dispatch_queue_t sessionQueue;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *videoCaptureDeviceInput;
@property(nonatomic, strong) AVCaptureStillImageOutput *stillImageOutput;
@property(nonatomic, strong) AVCaptureMetadataOutput *metadataOutput;
@property(nonatomic, strong) id runtimeErrorHandlingObserver;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, strong) CALayer *overlayLayer;
@property(nonatomic, strong) UIImage *overlayImage;
@property(nonatomic, strong) NSArray *barCodeTypes;

@property(nonatomic, assign) NSInteger presetCamera;
@property(nonatomic, assign) NSInteger flashMode;
@property(nonatomic, assign) CGFloat zoom;
@property(nonatomic, assign) BOOL mirrorImage;
@property(nonatomic, assign) NSInteger autoFocus;
@property(nonatomic, assign) float focusDepth;
@property(nonatomic, assign) NSInteger whiteBalance;
@property(nonatomic, assign, getter=isReadingBarCodes) BOOL barCodeReading;
@property(nonatomic, assign) AVVideoCodecType videoCodecType;

@property(nonatomic, strong) dispatch_queue_t frameBufferQueue;
@property(nonatomic, strong) AVAssetWriter *videoWriter;
@property(nonatomic, strong) AVAssetWriterInput* writerInput;
@property(nonatomic, strong) AVCaptureVideoDataOutput* videoOutput;
@property(nonatomic, assign) BOOL canAppendBuffer;
@property(nonatomic, assign) CMTime bufferTimestamp;
@property(nonatomic, assign) Float64 maxDuration;
@property(nonatomic, assign) CGPoint primaryFaceCenter;

- (id)initWithBridge:(RCTBridge *)bridge;
- (void)updateType;
- (void)updateFlashMode;
- (void)updateFocusMode;
- (void)updateFocusDepth;
- (void)updateZoom;
- (void)updateWhiteBalance;
- (void)updateFaceDetecting:(id)isDetectingFaces;
- (void)updateFaceDetectionMode:(id)requestedMode;
- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks;
- (void)updateFaceDetectionClassifications:(id)requestedClassifications;
- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)stopRecording;
- (void)setupOrDisableBarcodeScanner;
- (void)onReady:(NSDictionary *)event;
- (void)onMountingError:(NSDictionary *)event;
- (void)onCodeRead:(NSDictionary *)event;
- (void)onFacesDetected:(NSDictionary *)event;
- (void)stopAssetWriter;

@end
