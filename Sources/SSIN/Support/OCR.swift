import AppKit
@preconcurrency import Vision

enum OCR {
    /// Recognizes text with Vision (on-device), returning lines in reading order.
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations
                    .sorted { a, b in
                        // Top-to-bottom, then left-to-right (Vision uses a bottom-left origin).
                        abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01
                            ? a.boundingBox.midY > b.boundingBox.midY
                            : a.boundingBox.minX < b.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs OCR and puts the result on the clipboard, with a toast as feedback.
    @MainActor
    static func copyText(from image: CGImage) async {
        do {
            let text = try await recognize(image)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("No text found", symbol: "text.magnifyingglass", tint: .orange)
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            let preview = text.split(separator: "\n").prefix(2).joined(separator: " · ")
            Toast.show("Text copied", symbol: "text.viewfinder", detail: String(preview.prefix(90)))
        } catch {
            Toast.show("Text recognition failed", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription, tint: .orange)
        }
    }
}
