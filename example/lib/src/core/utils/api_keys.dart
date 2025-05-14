class ApiKeys {
  /// API Key for authentication with the Eleven Labs API.
  static const String elevenLabApiKey = String.fromEnvironment(
      'elevenLabApiKey',
      defaultValue: 'sk_c4b40976e12dcdfd16e72bad074e5533445fc2888884b41b');
  static const String deepgramApiKey = String.fromEnvironment('deepgramApiKey',
      defaultValue: '83f1555c78bc2d71b5fc040009cf38af393f0807');

  ///API key for the authentication with the Simli Avatar API
  static const String simliApiKey = String.fromEnvironment('simliApiKey',
      defaultValue: '0537w10dlpmlaa4zumeorc6');

  ///Api keys for the groq
  static const String groqApiKey = String.fromEnvironment('groqApiKey',
      defaultValue:
          'gsk_iq5X4MkfWr45f81wKrvQWGdyb3FYWMnLGLI8i7EvOxcW8iyxbc6V_');

  ///Api keys for the groq
  static const String gptApiKey =
      String.fromEnvironment('gptApiKey', defaultValue: '');
}
