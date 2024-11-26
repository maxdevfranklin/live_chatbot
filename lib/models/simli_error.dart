///Represent error with associated error code and message
class SimliError {
  ///initialize with message and errorCode
  SimliError({required this.message, this.errorCode});

  /// error code of any error
  String? errorCode;

  ///error message for the error
  String message;
}
