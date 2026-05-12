import Foundation

enum WhisperModel {
    static let filename = "ggml-large-v3-turbo.bin"
    static let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let expectedSHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    static let expectedBytes: Int = 1_624_555_275

    static var defaultDestinationURL: URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return app
            .appendingPathComponent("SayMoore/models", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
