// TODO: In production, move the API key to a backend proxy or Flutter Secure Storage.
// Never ship an app to the Play Store / App Store with the key hardcoded here.

// Groq
const String kOpenAiApiKey = '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';

// AssemblyAi
// const String kOpenAiApiKey = '318f774e8b184798a2a99a9ee62a1535';

// gladia
// const String kOpenAiApiKey = 'a8d91adb-f57b-4015-b970-e2de1ec2212a';


/// Whisper transcription language selector.
enum TranscriptionLanguage {
  /// Let Whisper auto-detect the language (no language param sent).
  auto,

  /// Force English transcription (language: "en").
  english,

  /// Force Hindi transcription (language: "hi").
  hindi,
}

extension TranscriptionLanguageExtension on TranscriptionLanguage {
  /// Returns the BCP-47 language code to send to Whisper, or null for auto.
  String? get apiCode {
    switch (this) {
      case TranscriptionLanguage.english:
        return 'en';
      case TranscriptionLanguage.hindi:
        return 'hi';
      case TranscriptionLanguage.auto:
        return null;
    }
  }

  /// Short display label for the UI toggle.
  String get label {
    switch (this) {
      case TranscriptionLanguage.auto:
        return 'Auto';
      case TranscriptionLanguage.english:
        return 'EN';
      case TranscriptionLanguage.hindi:
        return 'HI';
    }
  }
}
