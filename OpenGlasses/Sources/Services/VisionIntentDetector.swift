import Foundation

/// Lightweight, local detector that determines if a user query is vision-related
/// (needs camera input) or text-only (no camera needed).
///
/// Used by Smart Camera Activation to auto-activate the glasses camera only when
/// the query would benefit from visual input, saving battery and improving privacy.
/// Also used by the voice-message send path to decide whether to attach a photo.
///
/// This is purely keyword/pattern-based — no API calls, no latency.
///
/// Build 20: rewritten per Kyle's directive — wide phrase net, case/punctuation-
/// insensitive, bias toward capture on uncertainty when glasses are connected.
/// Old version had a narrow hardcoded phrase list that missed common variants like
/// "take a picture", "photo of", "describe this", "what's in front", "whats this"
/// (no apostrophe), etc. The new rule: if the message contains ANY visual-deixis
/// token (this/that/here + see/look/read/show/describe family), capture. A wasted
/// frame is cheap; a missed capture breaks the magic.
struct VisionIntentDetector {

    enum CameraIntent {
        case vision      // Query needs camera input
        case textOnly    // Query can be answered without vision
    }

    /// Determine if a transcript needs camera input.
    /// Errs on the side of activation — false negatives (missing a vision query)
    /// are worse than false positives (unnecessarily activating the camera).
    static func classify(_ transcript: String) -> CameraIntent {
        // Normalize: lowercase + strip punctuation so "What's this?" and "whats this"
        // and "WHAT IS THIS" all match the same phrases.
        let lower = normalize(transcript)

        // Direct vision trigger phrases (wide net)
        for phrase in visionPhrases {
            if lower.contains(phrase) { return .vision }
        }

        // Deictic references combined with action words that suggest visual context.
        // "this" + "see" / "look" / "read" / "show" / "describe" family → vision.
        for deictic in deicticPatterns {
            if lower.contains(deictic) { return .vision }
        }

        // Single-word or very short queries that are almost always visual.
        let words = lower.split(separator: " ")
        if words.count <= 4 {
            for trigger in shortVisionTriggers {
                if lower.contains(trigger) { return .vision }
            }
        }

        // Deixis + visual verb co-occurrence: if the message contains a deictic
        // token (this/that/these/those/here) AND a visual-verb token (see/look/
        // read/show/describe/scan/check/snap/picture/photo), treat as vision.
        // This catches "can you see this", "look at that", "read what's here",
        // "show me what's there", etc. that the exact phrase lists might miss.
        let hasDeictic = deixisTokens.contains(where: { lower.contains($0) })
        let hasVisualVerb = visualVerbTokens.contains(where: { lower.contains($0) })
        if hasDeictic && hasVisualVerb { return .vision }

        return .textOnly
    }

    // MARK: - Normalization

    /// Lowercase + strip apostrophes and punctuation so phrase matching is robust
    /// against "what's" vs "whats" vs "what is" vs "WHAT'S".
    private static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        // Collapse common contractions so we can list both forms but match uniformly.
        s = s.replacingOccurrences(of: "'", with: "")
        s = s.replacingOccurrences(of: "\u{2019}", with: "") // right single quote
        // Remove question marks, exclamation, periods, commas — they don't carry
        // vision intent and can break substring matches.
        let punctuation: Set<Character> = ["?", "!", ".", ",", ";", ":"]
        s = String(s.filter { !punctuation.contains($0) })
        // Collapse whitespace runs to single spaces so "what   is  this" matches.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Keyword Lists

    /// Phrases that strongly indicate a vision-related query.
    /// Listed in normalized form (no apostrophes, lowercase, no trailing punctuation).
    /// Update BOTH the apostrophe and non-apostrophe form for new phrases — or rely
    /// on normalize() to strip them (preferred).
    private static let visionPhrases: [String] = [
        // Direct camera/vision requests
        "look at", "looking at", "look at this", "look at that",
        "what do you see", "what can you see", "can you see",
        "what am i looking at", "what am i seeing",
        "what is this", "whats this", "what is that", "whats that",
        "what are these", "what are those", "what is in front",
        "whats in front", "whats in front of me",
        "show me", "describe what", "describe this", "describe that",
        "tell me what you see",
        "in front of me", "ahead of me", "around me",
        "what is in front of me", "what s in front of me",

        // Reading/text recognition
        "read this", "read that", "read the", "read what",
        "what does it say", "what does this say", "what does that say",
        "what does the sign say", "what does the menu say",
        "read the sign", "read the menu", "read the label", "read the text",
        "whats written", "what is written", "whats the text",

        // Object/scene identification
        "identify this", "identify that", "recognize this", "recognize that",
        "what kind of", "what type of", "what brand", "what model",
        "what plant", "what flower", "what bird", "what animal", "what bug", "what insect",
        "what painting", "what artwork", "who painted", "who made this",

        // Spatial/navigation
        "where am i", "what building", "what street", "what store",
        "which way", "how far", "how do i get",

        // Food/product
        "what food", "what dish", "how many calories", "what ingredients",
        "how much does", "whats the price", "what is the price", "whats it cost",

        // QR/barcode
        "scan this", "scan that", "scan the code", "scan the barcode", "scan the qr",
        "scan it",

        // Translation of visible text
        "translate this", "translate that", "translate the sign", "translate the menu",
        "what language is",

        // Color/appearance
        "what color", "what colour", "what color is this", "what colour is this",

        // Explicit camera commands
        "take a look", "check this out", "check that out", "check this",
        "see this", "see that", "see what", "do you see",
        "take a picture", "take a photo", "take a photo of", "take a picture of",
        "take photo", "take photo of", "take picture", "take picture of",
        "snap a photo", "snap a picture", "snap photo", "snap picture",
        "photo of", "picture of", "snap this", "snap that",
        "capture this", "capture that", "capture a photo",

        // "is this" — very common visual question starter
        "is this", "is that", "are these", "are those",
    ]

    /// Deictic references combined with action words that suggest visual context.
    private static let deicticPatterns: [String] = [
        "this is", "that is", "these are", "those are",
        "is this", "is that", "are these", "are those",
        "about this", "about that",
        "here is", "over here", "over there", "right here", "right there",
        "whats this", "what is this", "whats that", "what is that",
    ]

    /// Short queries (1-4 words) that are almost always visual.
    private static let shortVisionTriggers: [String] = [
        "this", "that", "whats this", "whats that",
        "what is this", "what is that",
        "read", "scan", "look", "see", "describe",
        "take a picture", "take a photo",
        "describe this", "describe that",
        "scan this", "scan that",
        "look at this", "look at that",
        "see this", "see that",
    ]

    /// Deictic tokens that, when co-occurring with a visual verb, suggest vision intent.
    private static let deixisTokens: [String] = [
        "this", "that", "these", "those", "here", "there",
    ]

    /// Visual-verb tokens that, when co-occurring with a deictic, suggest vision intent.
    private static let visualVerbTokens: [String] = [
        "see", "look", "read", "show", "describe", "scan", "check", "snap",
        "picture", "photo", "capture", "view", "watch",
    ]
}
