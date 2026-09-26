import AVFoundation
import Speech

/// Диктовка в поле чата (Настройки → Функции → Голосовой ввод). Распознавание — Speech, язык — язык интерфейса.
@MainActor
final class VoiceInput: ObservableObject {
	@Published private(set) var listening = false
	/// Распознанный текст текущей диктовки.
	@Published private(set) var text = ""

	private let engine = AVAudioEngine()
	private var request: SFSpeechAudioBufferRecognitionRequest?
	private var task: SFSpeechRecognitionTask?

	struct Failure: LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	func start() async throws {
		guard !listening else { return }
		let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
		guard speech == .authorized else { throw Failure(message: L("Speech recognition is not allowed — Settings → Privacy → Speech Recognition.")) }
		let mic = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
		guard mic else { throw Failure(message: L("The microphone is not allowed — Settings → Privacy → Microphone.")) }
		guard let rec = SFSpeechRecognizer(locale: Locale(identifier: L10n.isRussian ? "ru-RU" : "en-US")), rec.isAvailable else {
			throw Failure(message: L("Speech recognition is not available right now."))
		}

		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.record, mode: .measurement, options: .duckOthers)
		try session.setActive(true, options: .notifyOthersOnDeactivation)

		let req = SFSpeechAudioBufferRecognitionRequest()
		req.shouldReportPartialResults = true
		if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
		let input = engine.inputNode
		input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
		engine.prepare()
		try engine.start()
		request = req
		text = ""
		listening = true
		task = rec.recognitionTask(with: req) { [weak self] result, error in
			let t = result?.bestTranscription.formattedString
			let done = error != nil || (result?.isFinal ?? false)
			Task { @MainActor in
				guard let self else { return }
				if let t { self.text = t }
				if done { self.stop() }
			}
		}
	}

	func stop() {
		guard listening else { return }
		listening = false
		engine.stop()
		engine.inputNode.removeTap(onBus: 0)
		request?.endAudio()
		task?.finish()
		request = nil
		task = nil
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}
}
