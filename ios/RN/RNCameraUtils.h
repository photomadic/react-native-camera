//
//  RNCameraUtils.h
//  RCTCamera
//
//  Created by Joao Guilherme Daros Fidelis on 19/01/18.
//

#import <UIKit/UIKit.h>
#import "RNCameraManager.h"

@interface RNCameraUtils : NSObject

// Camera utilities
+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position;

// Enum conversions
+ (float)temperatureForWhiteBalance:(RNCameraWhiteBalance)whiteBalance;
+ (NSString *)captureSessionPresetForVideoResolution:(RNCameraVideoResolution)resolution;
+ (AVCaptureVideoOrientation)videoOrientationForInterfaceOrientation:(UIInterfaceOrientation)orientation;
+ (CGAffineTransform)videoTransformForOrientation:(UIInterfaceOrientation)orientation;
+ (CGImagePropertyOrientation)imageOrientationForFacialTracking:(UIInterfaceOrientation)orientation :(AVCaptureDevicePosition)camera;

@end
