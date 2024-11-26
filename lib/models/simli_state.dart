/// Represents the various states the Simli client can be in.
enum SimliState {
  ///When app is not connected
  ideal,

  ///while app is trying to connect
  connecting,

  ///when app is connected
  connected,

  ///when app is rendering avatar
  rendering,

  ///when app failed to connect
  failed
}
