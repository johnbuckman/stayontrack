import Foundation
import AVFoundation

/// Speaks turn instructions. For the three fixed commands ("Left", "Right",
/// "Straight") it plays high-quality pre-rendered clips (Kokoro "Lily", a posh
/// British female) bundled in the app — studio quality, fully offline. Anything
/// else falls back to on-device TTS (best installed voice).
final class VoiceAnnouncer {
    private let synth = AVSpeechSynthesizer()
    private let voice = VoiceAnnouncer.bestEnglishVoice()
    private var player: AVAudioPlayer?

    private let clips: [String: String] = [
        "Left": "v_left",
        "Right": "v_right",
        "Straight": "v_straight"
    ]

    func speak(_ text: String) {
        if let name = clips[text],
           let url = Bundle.main.url(forResource: name, withExtension: "m4a"),
           let audioPlayer = try? AVAudioPlayer(contentsOf: url) {
            player = audioPlayer
            audioPlayer.play()
            return
        }
        // Fallback: on-device synthesis.
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
