//
//  ViewController.swift
//  testObjectDetectRealTime
//
//  Created by Nguyen Duc Tai on 3/2/19.
//  Copyright © 2019 Nguyen Duc Tai. All rights reserved.
//

import UIKit
import AVKit
import Vision
import ARKit
import Alamofire
import SwiftyJSON

class ViewController: UIViewController {
  //MARK: IBOutlet variables
  @IBOutlet weak var previewView: PreviewView!
  @IBOutlet weak var nameLbl: UILabel!
  
  
  //MARK: Create variables
  //TODO: Count to request, if count > numberRequestData then Call API
  let numberRequestData = 15
  var countNumberToPushDataImage = 0
  var imageFullScreenWhenCountNumberRequest30: UIImage?
  
  // VNRequest: Either Retangles or Landmarks
  private var faceDetectionRequest: VNRequest!
  
  // TODO: Decide camera position --- front or back
  private var devicePosition: AVCaptureDevice.Position = .front
  
  // Session Management
  private enum SessionSetupResult {
    case success
    case notAuthorized
    case configurationFailed
  }
  
  private let session = AVCaptureSession()
  private var isSessionRunning = false
  
  // Communicate with the session and other session objects on this queue.
  private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], target: nil)
  
  private var setupResult: SessionSetupResult = .success
  
  private var videoDeviceInput:   AVCaptureDeviceInput!
  
  private var videoDataOutput:    AVCaptureVideoDataOutput!
  private var videoDataOutputQueue = DispatchQueue(label: "VideoDataOutputQueue")
  
  private var requests = [VNRequest]()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    // Set up the video preview view.
    previewView.session = session
    
    // Set up Vision Request
    faceDetectionRequest = VNDetectFaceRectanglesRequest(completionHandler: self.handleFaces) // Default
    setupVision()
    
    /*
     Check video authorization status. Video access is required and audio
     access is optional. If audio access is denied, audio is not recorded
     during movie recording.
     */
    switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video){
    case .authorized:
      // The user has previously granted access to the camera.
      break
      
    case .notDetermined:
      /*
       The user has not yet been presented with the option to grant
       video access. We suspend the session queue to delay session
       setup until the access request has completed.
       */
      sessionQueue.suspend()
      AVCaptureDevice.requestAccess(for: AVMediaType.video, completionHandler: { [unowned self] granted in
        if !granted {
          self.setupResult = .notAuthorized
        }
        self.sessionQueue.resume()
      })
      
      
    default:
      // The user has previously denied access.
      setupResult = .notAuthorized
    }
    
    /*
     Setup the capture session.
     In general it is not safe to mutate an AVCaptureSession or any of its
     inputs, outputs, or connections from multiple threads at the same time.
     
     Why not do all of this on the main queue?
     Because AVCaptureSession.startRunning() is a blocking call which can
     take a long time. We dispatch session setup to the sessionQueue so
     that the main queue isn't blocked, which keeps the UI responsive.
     */
    
    sessionQueue.async { [unowned self] in
      self.configureSession()
    }
    
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    sessionQueue.async { [unowned self] in
      switch self.setupResult {
      case .success:
        // Only setup observers and start the session running if setup succeeded.
        self.addObservers()
        self.session.startRunning()
        self.isSessionRunning = self.session.isRunning
        
      case .notAuthorized:
        DispatchQueue.main.async { [unowned self] in
          let message = NSLocalizedString("AVCamBarcode doesn't have permission to use the camera, please change privacy settings", comment: "Alert message when the user has denied access to the camera")
          let    alertController = UIAlertController(title: "AppleFaceDetection", message: message, preferredStyle: .alert)
          alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
          alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"), style: .`default`, handler: { action in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
          }))
          
          self.present(alertController, animated: true, completion: nil)
        }
        
      case .configurationFailed:
        DispatchQueue.main.async { [unowned self] in
          let message = NSLocalizedString("Unable to capture media", comment: "Alert message when something goes wrong during capture session configuration")
          let alertController = UIAlertController(title: "AppleFaceDetection", message: message, preferredStyle: .alert)
          alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
          
          self.present(alertController, animated: true, completion: nil)
        }
      }
    }
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    sessionQueue.async { [unowned self] in
      if self.setupResult == .success {
        self.session.stopRunning()
        self.isSessionRunning = self.session.isRunning
        self.removeObservers()
      }
    }
    
    super.viewWillDisappear(animated)
  }
  
  
  override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    
    if let videoPreviewLayerConnection = previewView.videoPreviewLayer.connection {
      let deviceOrientation = UIDevice.current.orientation
      guard let newVideoOrientation = deviceOrientation.videoOrientation, deviceOrientation.isPortrait || deviceOrientation.isLandscape else {
        return
      }
      
      videoPreviewLayerConnection.videoOrientation = newVideoOrientation
      
    }
  }
  
  // Segmente Control to switch over FaceOnly or FaceLandmark
  @IBAction func UpdateDetectionType(_ sender: UISegmentedControl) {
    faceDetectionRequest = sender.selectedSegmentIndex == 0 ? VNDetectFaceRectanglesRequest(completionHandler: handleFaces) : VNDetectFaceLandmarksRequest(completionHandler: handleFaceLandmarks)
    
    setupVision()
  }
  
  
}

//MARK: - Video Sessions
extension ViewController {
  private func configureSession() {
    if setupResult != .success { return }
    
    session.beginConfiguration()
    session.sessionPreset = .high
    
    // Add video input.
    addVideoDataInput()
    
    // Add video output.
    addVideoDataOutput()
    
    session.commitConfiguration()
    
  }
  
  private func addVideoDataInput() {
    do {
      var defaultVideoDevice: AVCaptureDevice!
      
      if devicePosition == .front {
        if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .front) {
          defaultVideoDevice = frontCameraDevice
        }
      }
      else {
        // Choose the back dual camera if available, otherwise default to a wide angle camera.
        if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: AVMediaType.video, position: .back) {
          defaultVideoDevice = dualCameraDevice
        }
          
        else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back) {
          defaultVideoDevice = backCameraDevice
        }
      }
      
      
      let videoDeviceInput = try AVCaptureDeviceInput(device: defaultVideoDevice!)
      
      if session.canAddInput(videoDeviceInput) {
        session.addInput(videoDeviceInput)
        self.videoDeviceInput = videoDeviceInput
        DispatchQueue.main.async {
          /*
           Why are we dispatching this to the main queue?
           Because AVCaptureVideoPreviewLayer is the backing layer for PreviewView and UIView
           can only be manipulated on the main thread.
           Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
           on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
           
           Use the status bar orientation as the initial video orientation. Subsequent orientation changes are
           handled by CameraViewController.viewWillTransition(to:with:).
           */
          let statusBarOrientation = UIApplication.shared.statusBarOrientation
          var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
          if statusBarOrientation != .unknown {
            if let videoOrientation = statusBarOrientation.videoOrientation {
              initialVideoOrientation = videoOrientation
            }
          }
          self.previewView.videoPreviewLayer.connection!.videoOrientation = initialVideoOrientation
        }
      }
      
    }
    catch {
      print("Could not add video device input to the session")
      setupResult = .configurationFailed
      session.commitConfiguration()
      return
    }
  }
  
  private func addVideoDataOutput() {
    videoDataOutput = AVCaptureVideoDataOutput()
    videoDataOutput.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as String): Int(kCVPixelFormatType_32BGRA)]
    
    
    if session.canAddOutput(videoDataOutput) {
      videoDataOutput.alwaysDiscardsLateVideoFrames = true
      videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
      session.addOutput(videoDataOutput)
    }
    else {
      print("Could not add metadata output to the session")
      setupResult = .configurationFailed
      session.commitConfiguration()
      return
    }
  }
}

// MARK: -- Observers and Event Handlers
extension ViewController {
  private func addObservers() {
    /*
     Observe the previewView's regionOfInterest to update the AVCaptureMetadataOutput's
     rectOfInterest when the user finishes resizing the region of interest.
     */
    NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: Notification.Name("AVCaptureSessionRuntimeErrorNotification"), object: session)
    
    /*
     A session can only run when the app is full screen. It will be interrupted
     in a multi-app layout, introduced in iOS 9, see also the documentation of
     AVCaptureSessionInterruptionReason. Add observers to handle these session
     interruptions and show a preview is paused message. See the documentation
     of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
     */
    NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: Notification.Name("AVCaptureSessionWasInterruptedNotification"), object: session)
    NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: Notification.Name("AVCaptureSessionInterruptionEndedNotification"), object: session)
  }
  
  private func removeObservers() {
    NotificationCenter.default.removeObserver(self)
  }
  
  @objc func sessionRuntimeError(_ notification: Notification) {
    guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else { return }
    
    let error = AVError(_nsError: errorValue)
    print("Capture session runtime error: \(error)")
    
    /*
     Automatically try to restart the session running if media services were
     reset and the last start running succeeded. Otherwise, enable the user
     to try to resume the session running.
     */
    if error.code == .mediaServicesWereReset {
      sessionQueue.async { [unowned self] in
        if self.isSessionRunning {
          self.session.startRunning()
          self.isSessionRunning = self.session.isRunning
        }
      }
    }
  }
  
  @objc func sessionWasInterrupted(_ notification: Notification) {
    /*
     In some scenarios we want to enable the user to resume the session running.
     For example, if music playback is initiated via control center while
     using AVCamBarcode, then the user can let AVCamBarcode resume
     the session running, which will stop music playback. Note that stopping
     music playback in control center will not automatically resume the session
     running. Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
     */
    if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?, let reasonIntegerValue = userInfoValue.integerValue, let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
      print("Capture session was interrupted with reason \(reason)")
    }
  }
  
  @objc func sessionInterruptionEnded(_ notification: Notification) {
    print("Capture session interruption ended")
  }
}

// TODO: -- Helpers
extension ViewController {
  func setupVision() {
    self.requests = [faceDetectionRequest]
  }
  
  func handleFaces(request: VNRequest, error: Error?) {
    DispatchQueue.main.async {
      //perform all the UI updates on the main queue
      guard let results = request.results as? [VNFaceObservation] else { return } //Results is number face observation
      self.previewView.removeMask()
      for face in results {
//        print(face.boundingBox)
        self.countNumberToPushDataImage = self.countNumberToPushDataImage + 1
        self.previewView.drawFaceboundingBox(face: face)
        
        if self.countNumberToPushDataImage > self.numberRequestData {
          self.countNumberToPushDataImage = 0
          
          guard let tempImage = self.imageFullScreenWhenCountNumberRequest30 else {return}
          
          //Rotate Image
          let rotateImage = self.imageRotatedByDegrees(oldImage: tempImage, deg: 90)
          
          //Transform Coordinate follow image physical size
          let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -rotateImage.size.height)
          
          let translate = CGAffineTransform.identity.scaledBy(x: rotateImage.size.width, y: rotateImage.size.height)
          // The coordinates are normalized to the dimensions of the processed image, with the origin at the image's lower-left corner.
          let facebounds = face.boundingBox.applying(translate).applying(transform)
          print(facebounds)
          
          //Extend Facebounds
          let extendRect = CGRect(x: facebounds.minX - 120, y: facebounds.minY - 250, width: facebounds.width + 120, height: facebounds.height + 250 )
          
          //Crop Image
          let cropImage = rotateImage.crop(rect: extendRect)
          
          self.callApi(image: cropImage)
          print("push data image")
        }
      }
    }
  }
  
  func handleFaceLandmarks(request: VNRequest, error: Error?) {
    DispatchQueue.main.async {
      //perform all the UI updates on the main queue
      guard let results = request.results as? [VNFaceObservation] else { return }
      self.previewView.removeMask()
      for face in results {
        self.previewView.drawFaceWithLandmarks(face: face)
      }
    }
  }
  
}

//TODO: -Camera Settings & Orientation
extension ViewController {
  func availableSessionPresets() -> [String] {
    let allSessionPresets = [AVCaptureSession.Preset.photo,
                             AVCaptureSession.Preset.low,
                             AVCaptureSession.Preset.medium,
                             AVCaptureSession.Preset.high,
                             AVCaptureSession.Preset.cif352x288,
                             AVCaptureSession.Preset.vga640x480,
                             AVCaptureSession.Preset.hd1280x720,
                             AVCaptureSession.Preset.iFrame960x540,
                             AVCaptureSession.Preset.iFrame1280x720,
                             AVCaptureSession.Preset.hd1920x1080,
                             AVCaptureSession.Preset.hd4K3840x2160]
    
    var availableSessionPresets = [String]()
    for sessionPreset in allSessionPresets {
      if session.canSetSessionPreset(sessionPreset) {
        availableSessionPresets.append(sessionPreset.rawValue)
      }
    }
    
    return availableSessionPresets
  }
  
  func exifOrientationFromDeviceOrientation() -> UInt32 {
    enum DeviceOrientation: UInt32 {
      case top0ColLeft = 1
      case top0ColRight = 2
      case bottom0ColRight = 3
      case bottom0ColLeft = 4
      case left0ColTop = 5
      case right0ColTop = 6
      case right0ColBottom = 7
      case left0ColBottom = 8
    }
    var exifOrientation: DeviceOrientation
    
    switch UIDevice.current.orientation {
    case .portraitUpsideDown:
      exifOrientation = .left0ColBottom
    case .landscapeLeft:
      exifOrientation = devicePosition == .front ? .bottom0ColRight : .top0ColLeft
    case .landscapeRight:
      exifOrientation = devicePosition == .front ? .top0ColLeft : .bottom0ColRight
    default:
      exifOrientation = devicePosition == .front ? .left0ColTop : .right0ColTop
    }
    return exifOrientation.rawValue
  }
  
  
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
      let exifOrientation = CGImagePropertyOrientation(rawValue: exifOrientationFromDeviceOrientation()) else { return }
    
    let imageBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
    let ciimage : CIImage = CIImage(cvPixelBuffer: imageBuffer)
    let image : UIImage = self.convert(cmage: ciimage)
    
    var requestOptions: [VNImageOption : Any] = [:]
    
    if let cameraIntrinsicData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) {
      requestOptions = [.cameraIntrinsics : cameraIntrinsicData]
    }
    
    let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: requestOptions)
    
    do {
      try imageRequestHandler.perform(requests)
    }
    catch {
      print(error)
    }
    
    //if count image > 30 then push full image
    if countNumberToPushDataImage > numberRequestData - 1 {
        imageFullScreenWhenCountNumberRequest30 = image
    }
    
  }
  // Convert CIImage to CGImage
  func convert(cmage:CIImage) -> UIImage
  {
    let context:CIContext = CIContext.init(options: nil)
    let cgImage:CGImage = context.createCGImage(cmage, from: cmage.extent)!
    let image:UIImage = UIImage.init(cgImage: cgImage)
    return image
  }
  
}

//MARK: -Request API
extension ViewController {
  func callApi(image: UIImage) {
    let imageData = image.jpegData(compressionQuality: 0.3)
    
//    let headers = [
//      "Content-Type": "application/octet-stream",
//      ]
    
    
    Alamofire.upload(imageData!, to: "http://192.168.1.60:8687/identify", method: .post, headers: nil).responseJSON { (response) in
      let json = JSON(response.result.value)
      print(json["FullName"])
      let name = json["FullName"].string
      if response.result.isSuccess {
      self.nameLbl.text = name
      self.nameLbl.isHidden = false
      } else {
        self.nameLbl.isHidden = true
      }
      
    }
    
  }
}

//TODO: -CROP Image
extension UIImage {
  func crop( rect: CGRect) -> UIImage {
    var rect = rect
    rect.origin.x*=self.scale
    rect.origin.y*=self.scale
    rect.size.width*=self.scale
    rect.size.height*=self.scale
    
    let imageRef = self.cgImage!.cropping(to: rect)
    let image = UIImage(cgImage: imageRef!, scale: self.scale, orientation: self.imageOrientation)
    return image
  }
  
}

//TODO: Resize image
extension UIViewController {
  func imageRotatedByDegrees(oldImage: UIImage, deg degrees: CGFloat) -> UIImage {
    //Calculate the size of the rotated view's containing box for our drawing space
    let rotatedViewBox: UIView = UIView(frame: CGRect(x: 0, y: 0, width: oldImage.size.width, height: oldImage.size.height))
    let t: CGAffineTransform = CGAffineTransform(rotationAngle: degrees * CGFloat.pi / 180)
    rotatedViewBox.transform = t
    let rotatedSize: CGSize = rotatedViewBox.frame.size
    //Create the bitmap context
    UIGraphicsBeginImageContext(rotatedSize)
    let bitmap: CGContext = UIGraphicsGetCurrentContext()!
    //Move the origin to the middle of the image so we will rotate and scale around the center.
    bitmap.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
    //Rotate the image context
    bitmap.rotate(by: (degrees * CGFloat.pi / 180))
    //Now, draw the rotated/scaled image into the context
    bitmap.scaleBy(x: 1.0, y: -1.0)
    bitmap.draw(oldImage.cgImage!, in: CGRect(x: -oldImage.size.width / 2, y: -oldImage.size.height / 2, width: oldImage.size.width, height: oldImage.size.height))
    let newImage: UIImage = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    return newImage
  }
  
}



