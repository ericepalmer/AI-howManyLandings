import UniformTypeIdentifiers

extension UTType {
    /// JSON Lines — one JSON poll object per line (`capture_adsb.py` output).
    static let jsonLines = UTType(filenameExtension: "jsonl", conformingTo: .plainText)!

    /// adsb.lol capture files saved with a `.lol` extension (also JSONL).
    static let adsbLolCapture = UTType(filenameExtension: "lol", conformingTo: .plainText)!
}

enum RecordedADSFileTypes {
    static let importable: [UTType] = [
        .json,
        .jsonLines,
        .adsbLolCapture,
        .plainText,
        .text,
    ]
}
