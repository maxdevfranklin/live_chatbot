import 'package:web_socket_client/web_socket_client.dart';

/// Extension on the [WebSocket] class to provide additional functionalities.
extension WebSocketExtension on WebSocket {
  /// Checks if the WebSocket connection is in a connected state.
  bool get isConnected {
    return connection.state is Connected;
  }
}
