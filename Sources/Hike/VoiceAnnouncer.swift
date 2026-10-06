import Foundation
import AVFoundation
import os

/// Speaks the hike's spoken cues. Every fixed phrase plays a pre-rendered clip
/// bundled in the app (Kokoro-82M voice `bf_emma`, a posh British female) —
/// studio quality and fully offline. Only genuinely variable text falls back to
/// on-device TTS, which sounds like a different person and is why every fixed
/// phrase belongs in `clips`: add a cue here and record it, or it will stand out.
///
/// Regenerating a clip: `pip install kokoro-onnx soundfile`, `brew install
/// espeak-ng`, fetch `kokoro-v1.0.onnx` + `voices-v1.0.bin` from the
/// thewh1teagle/kokoro-onnx `model-files-v1.0` release, then
/// `Kokoro(...).create("Paused.", voice="bf_emma", lang="en-gb")` → wav →
/// `afconvert -f m4af -d aac` → `Resources/v_<name>.m4a`. Keep the trailing full
/// stop: it gives the phrase a falling, finished intonation.
final class VoiceAnnouncer {
    private let synth = AVSpeechSynthesizer()
    private let voice = VoiceAnnouncer.bestEnglishVoice()
    private var player: AVAudioPlayer?

    private let clips: [String: String] = [
        "Left": "v_left",
        "Right": "v_right",
        "Straight": "v_straight",
        "20 meters off trail": "v_off20",
        "50 meters off trail": "v_off50",
        "100 meters off trail": "v_off100",
        "Wrong turn": "v_wrongturn",
        "Back on trail": "v_backontrail",
        "Auto paused": "v_autopaused",
        "Paused": "v_paused",
        "Resumed": "v_resumed"
    ]

    func speak(_ text: String) {
        if let name = clips[text],
           let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
           let audioPlayer = try? AVAudioPlayer(contentsOf: url) {
            player = audioPlayer
            audioPlayer.play()
            return
        }
        // Fallback: on-device synthesis. It is noticeably a different person,
        // so a fixed phrase reaching here is a bug — John spotted "Auto paused"
        // and "Resumed" by ear. Say so in the log rather than waiting for ears.
        #if DEBUG
        Logger(subsystem: "com.johnbuckman.stayontrack", category: "voice")
            .error("no bundled clip for \"\(text, privacy: .public)\" — falling back to robot TTS")
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        player?.stop()
        synth.stopSpeaking(at: .immediate)
    }

    /// Highest-quality English voice installed (fallback only): premium ▸
    /// enhanced ▸ default, preferring en-GB.
    private static func bestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func localeRank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.language {
            case "en-GB": return 0
            case "en-US": return 1
            case "en-AU": return 2
            default:      return 3
            }
        }
        func best(_ quality: AVSpeechSynthesisVoiceQuality) -> AVSpeechSynthesisVoice? {
            english.filter { $0.quality == quality }.min { localeRank($0) < localeRank($1) }
        }
        return best(.premium) ?? best(.enhanced) ?? best(.default)
    }
}
