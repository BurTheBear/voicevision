# VoiceVision

An iPhone app that helps blind and low-vision people get around. Point the camera ahead and it says what's in front of you, warns you about obstacles, and vibrates more as something gets closer. I made it for the GAICOM 2025 AI Hackathon, where it won 1st place.

Everything runs on the phone with Core ML. Nothing is sent to a server.

## How it works

Each camera frame goes through three models:

- **YOLOv8** finds objects and draws boxes around them (red for people, blue for furniture, purple for electronics, green for everything else).
- **Depth Anything V2** guesses how far away each part of the picture is, from a single camera.
- **FastViT** classifies the whole scene.

`VisionFusionPipeline.swift` combines them. It looks up the depth inside each box to tell how close an object is, and compares that with earlier frames to tell whether it's coming closer or moving away. Then:

- A strong constant vibration means something is about a foot away. Short pulses mean something is getting closer. Soft ticks mean it's moving away.
- It says "Obstacle ahead" and tells you to go left or right, or says "Stop" if something is within a foot.
- It can speak and show subtitles in English, Spanish, French or Hindi.

It's not a safety device, and the app's instructions say so.

## Running it

The models are too big for GitHub, so add them to the `voicevision` folder in Xcode before building:

- `DepthAnythingV2SmallF16.mlpackage` and `FastViTMA36F16.mlpackage` from Apple's Core ML models page (developer.apple.com/machine-learning/models).
- `yolov8l 2.mlpackage`, exported from Ultralytics with `yolo export model=yolov8l.pt format=coreml nms=True` and renamed.

Then pick your own team under Signing & Capabilities and run it on an iPhone (the camera doesn't work in the simulator). Swift, SwiftUI, AVFoundation, Vision, Core ML and Core Haptics.

MIT license, for my code. The models have their own licenses.
