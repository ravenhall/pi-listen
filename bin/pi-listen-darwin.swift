#!/usr/bin/env swift
import AVFoundation
import Foundation
import Speech

final class Listener {
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committedText = ""
    private var pendingFinal: DispatchWorkItem?

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                self.emit("error", "Speech recognition permission was not granted.")
                exit(1)
            }

            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                guard allowed else {
                    self.emit("error", "Microphone permission was not granted.")
                    exit(1)
                }

                do {
                    try self.run()
                    RunLoop.main.run()
                } catch {
                    self.emit("error", error.localizedDescription)
                    exit(1)
                }
            }
        }
    }

    private func run() throws {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            emit("error", "macOS speech recognizer is not available.")
            exit(1)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.emitFinalDelta(text)
                } else {
                    self.emit("streaming", text)
                    self.scheduleFinalDelta(text)
                }
            }

            if let error {
                self.emit("error", error.localizedDescription)
                self.stop()
                exit(1)
            }
        }
    }

    func stop() {
        pendingFinal?.cancel()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
    }

    private func scheduleFinalDelta(_ text: String) {
        pendingFinal?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.emitFinalDelta(text)
        }
        pendingFinal = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func emitFinalDelta(_ text: String) {
        pendingFinal?.cancel()
        let delta: String
        if text.hasPrefix(committedText) {
            delta = String(text.dropFirst(committedText.count))
        } else {
            delta = text
        }

        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        committedText = text
        emit("final", trimmed)
    }

    private func emit(_ status: String, _ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        print("\(status)\t\(text)")
        fflush(stdout)
    }
}

let listener = Listener()
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
listener.start()
