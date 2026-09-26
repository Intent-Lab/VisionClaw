import AVFoundation
import Foundation

/// Short audio cues for call-state changes, played in assistive mode.
///
/// Blind users cannot see the call screen, and VoiceOver announcements only
/// reach people who run VoiceOver -- often not the case for older users, who
/// are exactly who assistive mode is for. A cue in the ear is the one signal
/// that always lands, so the user never talks into a dead call without knowing.
///
/// The tones are synthesized in memory rather than shipped as sound files, and
/// played through AVAudioPlayer on whatever session LiveKit has configured, so
/// during a glasses call they come out of the glasses with the agent's voice.
/// The same note sequences are used on Android (livekit/Earcons.kt); keep the
/// two in step so a cue means the same thing on both platforms.
@MainActor
enum Earcons {
  enum Cue {
    case connected
    case ended
    case lost
    case reconnected
    case captured

    /// (frequency Hz, duration s); a frequency of 0 is a rest.
    fileprivate var notes: [(Double, Double)] {
      switch self {
      case .connected: return [(660, 0.09), (0, 0.03), (990, 0.12)]
      case .ended: return [(990, 0.09), (0, 0.03), (660, 0.12)]
      case .lost: return [(520, 0.15), (0, 0.06), (390, 0.25)]
      case .reconnected: return [(660, 0.07), (0, 0.02), (830, 0.07), (0, 0.02), (990, 0.1)]
      case .captured: return [(1800, 0.04)]
      }
    }
  }

  private static let sampleRate = 44_100.0
  private static var cache: [String: Data] = [:]
  // AVAudioPlayer stops when released; hold each until it has played out.
  private static var playing: [AVAudioPlayer] = []

  /// Plays `cue` if assistive mode is on. Safe to call from any state change.
  static func play(_ cue: Cue) {
    guard SettingsManager.shared.assistiveMode else { return }
    let key = "\(cue)"
    let data = cache[key] ?? wav(for: cue.notes)
    cache[key] = data
    guard let player = try? AVAudioPlayer(data: data) else { return }
    player.volume = 0.8
    playing.removeAll { !$0.isPlaying }
    playing.append(player)
    player.play()
  }

  /// 16-bit mono PCM in a WAV container. Each note gets a short fade in and
  /// out so it starts and stops without a click.
  private static func wav(for notes: [(Double, Double)]) -> Data {
    var samples: [Int16] = []
    let fade = Int(sampleRate * 0.008)
    for (frequency, duration) in notes {
      let count = Int(sampleRate * duration)
      for i in 0..<count {
        guard frequency > 0 else { samples.append(0); continue }
        let envelope = min(1, Double(min(i, count - 1 - i)) / Double(fade))
        let value = sin(2 * .pi * frequency * Double(i) / sampleRate) * 0.35 * envelope
        samples.append(Int16(value * Double(Int16.max)))
      }
    }
    let byteCount = samples.count * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(UInt32(sampleRate))
    append(UInt32(sampleRate) * 2)  // byte rate
    append(UInt16(2))  // block align
    append(UInt16(16))  // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(byteCount))
    samples.forEach { append($0) }
    return data
  }
}
