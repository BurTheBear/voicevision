//
//  CameraPermissionDebugView.swift
//  voicevision
//
//  Created by Atharv Sharma on 11/4/25.
//

import SwiftUI
import AVFoundation

struct CameraPermissionDebugView: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        VStack(spacing: 20) {
            Text("Camera status: \(String(describing: status))")
                .multilineTextAlignment(.center)

            Button("Request Camera Access") {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        status = AVCaptureDevice.authorizationStatus(for: .video)
                        print("Granted? \(granted)  New status: \(status)")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
