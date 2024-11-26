///Exception for simli class
class SimliException implements Exception {
  /// Constructor for creating a [SimliException] with a
  /// specified [errorCode] and [message].
  SimliException(this.errorCode, this.message);

  /// Error code associated with this exception.
  final String errorCode;

  /// Message providing details about the exception.
  final String message;

  @override
  String toString() =>
      'SimliException(errorCode: $errorCode, message: $message)';
}

class SimliExceptionCode {
  static String noIceServes = "no-iceservers";
}
