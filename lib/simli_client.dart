import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:logging/logging.dart';
import 'package:simli_client/extension/websocket_extension.dart';
import 'package:simli_client/models/simli_client_config.dart';
import 'package:simli_client/models/simli_error.dart';
import 'package:simli_client/models/simli_exception.dart';
import 'package:simli_client/models/simli_state.dart';
import 'package:web_socket_client/web_socket_client.dart';

/// Represents a client for interacting with the Simli API and managing WebRTC
/// connections, including video rendering, peer connections, and data channels.
class SimliClient {
  /// Creates a new [SimliClient] instance.

  SimliClient({
    required this.clientConfig,
    required this.log,
  }) {
    videoRenderer = RTCVideoRenderer();
    videoRenderer!.initialize();
  }
  Logger log;

  /// client config for the session
  SimliClientConfig clientConfig;

  /// The WebRTC peer connection.
  RTCPeerConnection? peerConnection;

  /// The video renderer used for displaying video streams.
  RTCVideoRenderer? videoRenderer;

  /// Timer for monitoring audio levels.
  Timer? audioLEvelTimer;

  /// Timer for monitoring audio levels.
  Timer? connectionTimeOutTimer;

  /// The number of ICE candidates found.
  int candidateCount = 0;

  /// Tracks the previous ICE candidate count.
  int prevCandidateCount = -1;

  /// Notifies listeners of changes to the client's state.
  ValueNotifier<SimliState> stateNotifier = ValueNotifier(SimliState.ideal);

  /// Notifies listeners of changes in whether the user is speaking.
  ValueNotifier<bool> isSpeakingNotifier = ValueNotifier(false);

  /// A callback for handling connection events.
  VoidCallback? onConnection;

  /// A callback for handling connection failed events.
  void Function(SimliError error)? onFailed;

  /// A callback for handling disconnection events.
  VoidCallback? onDisconnected;

  /// Gets whether the user is currently speaking.
  bool get isSpeaking => isSpeakingNotifier.value;

  /// Sets whether the user is currently speaking.
  set isSpeaking(bool value) {
    isSpeakingNotifier.value = value;
  }

  /// Gets current state of the client.
  SimliState get state => stateNotifier.value;

  /// Gets current state of the client.
  set state(SimliState state) {
    stateNotifier.value = state;
  }

  /// Notifies listeners with audio level of the avatar.
  ValueNotifier<double> audioLevelNotifier = ValueNotifier(0);

  ///websocket connection for communication
  WebSocket? webSocket;

  ///it will be true if session is initialized
  bool sessionInitialized = false;

  // Map<String, int> pingSendTimes = {};
  ///store the time of last send time of data
  int lastSendTime = 0;

  ///it will hold the reason for the error
  String? errorReason;

  ///it will update client config
  void updateConfig(SimliClientConfig clientConfig) {
    this.clientConfig = clientConfig;
  }

  MediaStreamTrack? _audioStreamTack;

  /// Returns a list of ICE servers.
  ///
  /// The function retrieves ICE servers using an API key with the
  ///  specified retry and timeout configurations.
  /// If fetching fails, a default STUN server is provided.
  Future<dynamic> getIceServers({
    required int maxRetry,
    required Duration retryDelay,
    required String apiKey,
    required Duration requestTimeout,
  }) async {
    final client = RetryClient(
      http.Client(),
      retries: maxRetry,
      delay: (retryCount) => retryDelay,
      onRetry: (p0, p1, retryCount) {
        logException('ICE servers fetch attempt $retryCount failed: $p1');
      },
    );
    try {
      final response = await client
          .post(
            Uri.parse('https://api.simli.ai/getIceServers'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'apiKey': apiKey}),
          )
          .timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw SimliException(
          'http-status-code',
          'HTTP error! status: ${response.statusCode}',
        );
      }
      final iceServers = jsonDecode(response.body) as List<dynamic>;
      if (iceServers.isEmpty) {
        throw SimliException(
          SimliExceptionCode.noIceServes,
          'No ICE servers returned',
        );
      }
      return List<Map<String, dynamic>>.from(iceServers);
    } catch (error) {
      logInfo('Using fallback STUN server: $error');
      return [
        {'urls': 'stun:stun.l.google.com:19302'},
      ];
    } finally {
      client.close();
    }
  }

  /// Creates a WebRTC peer connection and sets up listeners.
  Future<void> createRTCPeerConnection() async {
    final configuration = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'iceServers': await getIceServers(
        maxRetry: clientConfig.maxRetryAttempts,
        apiKey: clientConfig.apiKey,
        requestTimeout: clientConfig.requestTimeout,
        retryDelay: clientConfig.retryDelay,
      ),
    };

    try {
      peerConnection = await createPeerConnection(configuration);
      logSuccess('Peer connection created');
    } catch (e) {
      handleConnectionFailure('Failed to create peer connection: $e');
      return;
    }
    logSuccess('Peer connection created');
    setupPeerConnectionListener();
  }

  /// Sets up listeners for WebRTC peer connection events.
  void setupPeerConnectionListener() {
    if (peerConnection == null) return;
    peerConnection?.onIceGatheringState = (RTCIceGatheringState value) {
      logInfo('ICE gathering state changed: $value');
    };
    peerConnection?.onIceConnectionState = (RTCIceConnectionState state) {
      logInfo('ICE connection state changed: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        logSuccess(
          'WebRTC connection established and ready for communication.',
        );
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        handleConnectionFailure('ICE connection failed');
      }
    };
    peerConnection?.onSignalingState = (RTCSignalingState value) {
      logInfo('Signal state changed: $value');
    };
    peerConnection?.onAddStream = _addVideoStream;
    peerConnection?.onTrack = (RTCTrackEvent value) {
      logInfo('Track Kind: ${value.track.kind}');
      if (value.track.kind == 'video') {
        if (value.streams.isNotEmpty) {
          _addVideoStream(value.streams.first);
        } else {
          logException('Track added, but no associated stream found');
          handleConnectionFailure(
            'Track added, but no associated stream found',
          );
        }
      } else {
        _audioStreamTack = value.track;
      }
    };
    peerConnection?.onIceCandidate = (RTCIceCandidate value) async {
      if (value.candidate == null) {
        // logInfo(await peerConnection?.getLocalDescription());
      } else {
        // logInfo(value.candidate);
        candidateCount += 1;
      }
    };
    logInfo('Registered all listener for the connection ');
  }

  void _setupConnectionStateHandler() {
    if (peerConnection == null) return;

    peerConnection!.onConnectionState = (_) {
      switch (peerConnection!.connectionState!) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          clearTimeouts();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          handleConnectionFailure('Connection failed or closed');
          cleanup();
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          handleDisconnection();

        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          logInfo('Connection state is New');
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          logInfo('Connection is in progress');
      }
    };
  }

  /// Starts the WebRTC session by creating the peer connection, adding data
  /// channels, and negotiating.

  Future<void> start({int retryAttempt = 1}) async {
    try {
      clearTimeouts();
      state = SimliState.connecting;
      connectionTimeOutTimer = Timer(
        clientConfig.connectionTimeoutTime,
        handleConnectionTimeout,
      );
      await createRTCPeerConnection();
      _setupConnectionStateHandler();
      unawaited(
        peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        ),
      );
      unawaited(
        peerConnection?.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        ),
      );
      await negotiate();
      clearTimeouts();
    } on Exception catch (e) {
      logException('Connection attempt $retryAttempt failed: $e');
      clearTimeouts();

      if (retryAttempt < clientConfig.maxRetryAttempts) {
        logInfo('Retrying connection... Attempt ${retryAttempt + 1}');
        await Future<void>.delayed(clientConfig.retryDelay);
        await cleanup();
        return start(retryAttempt: retryAttempt + 1);
      }
      handleConnectionFailure(
        'Failed to connect after ${clientConfig.maxRetryAttempts} attempts',
      );
    }
  }

  /// Initializes a session by sending metadata to a remote API.
  ///
  /// This method sends a POST request to the Simli API to start an
  /// audio-to-video session. Upon success, it sends the session token over
  ///  the data channel.
  ///
  /// The metadata includes the reference video URL, face ID, API key, and other
  ///  parameters. Throws an exception if the session cannot be initialized.
  Future<void> initializeSession() async {
    // Metadata to send to the API for session initialization.
    final metadata = <String, dynamic>{
      'video_reference_url':
          'https://storage.googleapis.com/charactervideos/5514e24d-6086-46a3-ace4-6a7264e5cb7c/5514e24d-6086-46a3-ace4-6a7264e5cb7c.mp4',
      'isJPG': false,
    }..addAll(clientConfig.toJson());

    try {
      // Send a POST request to the server with the metadata.
      final response = await http.post(
        Uri.parse('https://api.simli.ai/startAudioToVideoSession'),
        headers: <String, String>{
          'Content-Type': 'application/json',
        },
        body: jsonEncode(metadata),
      );

      // Check if the request was successful.
      if (response.statusCode == 200) {
        // Retrieve the session token from the response.
        final sessionToken =
            (jsonDecode(response.body) as Map)['session_token'].toString();

        if (webSocket != null && webSocket!.isConnected) {
          // Send the session token over the data channel.
          webSocket?.send(sessionToken);
          logSuccess('Token is sent');
        } else {
          onFailed?.call(
            SimliError(
              message:
                  'Data channel not open when trying to send session token',
            ),
          );
          state = SimliState.failed;
        }

        logInfo('Session initialized successfully');
      } else {
        // Log an error if the request fails.
        logException('Failed to start session: ${response.statusCode}');
        logException('Response body: ${response.body}');
        handleConnectionFailure(
          'Failed to start session: ${response.statusCode}',
        );
        await peerConnection?.close();
      }
    } catch (error) {
      handleConnectionFailure('Session initialization failed: $error');
      await peerConnection?.close();
    }
  }

  /// Negotiates a WebRTC connection by creating an offer, setting the local
  /// description, gathering ICE candidates, and exchanging session details
  /// with the server.
  ///
  /// Throws a [PlatformException] if the [peerConnection] is not initialized.
  Future<void> negotiate() async {
    logInfo('Negotiation started');
    if (peerConnection == null) {
      throw PlatformException(code: 'peer-connection-not-initialized');
    }

    try {
      // Create an offer for the peer connection.
      final description = await peerConnection?.createOffer();
      await peerConnection?.setLocalDescription(description!);

      // Wait for ICE gathering to complete before proceeding.
      await waitForIceGathering();

      // Retrieve the local description after ICE gathering.
      final localDescription = await peerConnection?.getLocalDescription();
      if (localDescription == null) {
        return;
      }

      webSocket = WebSocket(
        Uri.parse('wss://api.simli.ai/StartWebRTCSession'),
        timeout: const Duration(seconds: 20),
      );
      RTCSessionDescription? answer;
      // Listen to messages
      webSocket?.messages.listen(
        (data) async {
          logInfo('Received message: $data');

          if (data == 'START') {
            sessionInitialized = true;
            state = SimliState.connected;
            onConnection?.call();
            _startAudioLevelChecking();
            logInfo('Session is initialized');
            sendAudioData(Uint8List.fromList(List.filled(6000, 255)));
          } else if (data == 'STOP') {
            await close();
          } else if (data.toString().startsWith('pong')) {
            // final pingKey = (data as String).replaceFirst('pong', 'ping');
            // final pingTime = pingSendTimes[pingKey];
            // if (pingTime != null) {
            //   logInfo(
            //'Simli Latency: ${DateTime.now().millisecondsSinceEpoch - pingTime}',
            //   );
            // }
          } else if (data == 'ACK') {
            logInfo('Received ACK');
          } else {
            try {
              logInfo('Received  answer');
              final message =
                  jsonDecode(data as String) as Map<String, dynamic>;
              if (message['type'] == 'answer') {
                answer = RTCSessionDescription(
                  message['sdp'].toString(),
                  message['type'].toString(),
                );
              }
            } catch (e) {
              logException('Error parsing message: $e');
            }
          }
        },
        onError: (dynamic error) {
          logException('Error: $error');

          handleConnectionFailure('WebSocket has error $error');
        },
        onDone: () {
          logInfo('WebSocket closed');

          handleConnectionFailure('WebSocket closed unexpectedly');
        },
      );
      // Wait until a connection has been established.
      await webSocket?.connection.firstWhere((state) => state is Connected);
      logSuccess('Websocket is connected');
      // final wsConnectCompleter = Completer<void>();
      // logInfo('Sending: ${localDescription.toMap()}');
      logInfo('Sending SDP Data');
      webSocket?.send(jsonEncode(localDescription.toMap()));
      logSuccess('local description send');
      // Initialize the session when the data channel is open.
      await initializeSession();

      // wsConnectCompleter.complete();

      // Wait for answer with timeout
      final answerCompleter = Completer<void>();
      Timer? timeoutTimer;

      void checkAnswer() {
        if (answer != null) {
          timeoutTimer?.cancel();
          peerConnection!.setRemoteDescription(
            RTCSessionDescription(answer!.sdp, answer!.type),
          );
          logSuccess('Setting remote description: ');
          answerCompleter.complete();
        } else {
          Future.delayed(const Duration(milliseconds: 100), checkAnswer);
        }
      }

      timeoutTimer = Timer(const Duration(seconds: 10), () {
        if (!answerCompleter.isCompleted) {
          answerCompleter
              .completeError(TimeoutException('SIMLI: Answer timeout'));
        }
      });

      checkAnswer();
      logInfo('Negotiation finished');
      await answerCompleter.future;
    } catch (e) {
      // Handle any additional errors in offer creation or session negotiation.
      logException('Error during negotiation: $e');

      handleConnectionFailure('Error during negotiation: $e');
    }
  }

  /// Waits for the ICE gathering process to complete.
  ///
  /// This method completes once the ICE candidates have been gathered.

  // Future<void> waitForIceGathering() async {
  //   if (peerConnection == null) return;

  //   if (peerConnection!.iceGatheringState ==
  //       RTCIceGatheringState.RTCIceGatheringStateComplete) {
  //     return;
  //   }
  //   logInfo('Waiting For ICE Gathering');
  //   final completer = Completer<void>();
  //   Timer? timeout;

  //   void checkIceCandidates() {
  //     logInfo('Checking canddate');
  //     if (peerConnection!.iceGatheringState ==
  //             RTCIceGatheringState.RTCIceGatheringStateComplete ||
  //         candidateCount == prevCandidateCount) {
  //       timeout?.cancel();
  //       completer.complete();
  //     } else {
  //       prevCandidateCount = candidateCount;
  //       Future.delayed(const Duration(milliseconds: 250), checkIceCandidates);
  //     }
  //   }

  //   timeout = Timer(const Duration(seconds: 10), () {
  //     if (!completer.isCompleted) {
  //       completer.completeError(Exception('ICE gathering timeout'));
  //     }
  //   });

  //   checkIceCandidates();
  //   logInfo('Checking candiate checking done');
  //   return completer.future;
  // }

  Future<void> waitForIceGathering() async {
    if (peerConnection?.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    peerConnection?.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        completer.complete();
      }
    };
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw Exception('ICE gathering timeout');
      },
    );
  }

  /// it will handle connection failure
  void handleConnectionFailure(String reason) {
    errorReason = reason;
    logException('Connection failure: $reason');

    onFailed?.call(
      SimliError(
        message: reason,
      ),
    );
    cleanup();
  }

  ///it will handle connection timeout
  void handleConnectionTimeout() {
    handleConnectionFailure('Connection timed out');
  }

  ///handle disconnection of the webrtc connection
  void handleDisconnection() {
    if (sessionInitialized) {
      logException('Connection lost, attempting to reconnect...');
      cleanup().then((value) {
        start();
      }).onError(
        (error, stackTrace) {
          logException('Reconnection failed:  $error');
          handleConnectionFailure('Reconnection failed');
        },
      );
    }
  }

  ///it will cleanup the current resource
  Future<void> cleanup() async {
    await peerConnection?.close();
    peerConnection = null;
    webSocket?.close();
    webSocket = null;
    clearTimeouts();
    sessionInitialized = false;
    candidateCount = 0;
    prevCandidateCount = -1;
    errorReason = null;
    logInfo('Resources cleaned up');
  }

  ///it will clear connection timeout
  void clearTimeouts() {
    connectionTimeOutTimer?.cancel();
    connectionTimeOutTimer = null;
  }

  /// Sends audio data over the data channel.
  ///
  /// This method ensures that the data channel is open before sending
  /// audio data. If the channel is not open, it logs an exception.
  ///
  /// [audioData] is the binary audio data to be sent.

  void sendAudioData(Uint8List audioData) {
    if (!sessionInitialized) {
      logException('Session not initialized. Ignoring audio data.');
      return;
    }

    if (webSocket != null) {
      try {
        if (sessionInitialized) {
          webSocket!.send(audioData);
          logSuccess('Data Sent: ${audioData.length}');
          if (lastSendTime != 0) {
            logInfo(
              'Time between sends: ${DateTime.now().millisecondsSinceEpoch - lastSendTime}',
            );
          }
          lastSendTime = DateTime.now().millisecondsSinceEpoch;
        } else {
          logInfo(
            'Data channel open but session is being initialized. Ignoring audio data.',
          );
        }
      } catch (error) {
        logException('Failed to send audio data: $error');
      }
    } else {
      logException('Data channel is not open. Error Reason: $errorReason');
    }
  }

  /// Adds a video stream to the video renderer and sets up audio settings.
  ///
  /// This method configures the [videoRenderer] to display the incoming video
  /// stream. It also manages audio settings, such as enabling the speakerphone
  ///  on mobile devices. [stream] is the incoming media stream containing video and/or audio tracks.
  void _addVideoStream(MediaStream stream) {
    logSuccess(stream.getVideoTracks());
    // Set the source of the video renderer to the incoming media stream.
    videoRenderer?.srcObject = stream;
    logSuccess('Video stream added');
    // Log when the first video frame is rendered.
    videoRenderer?.onFirstFrameRendered = () {
      logSuccess('First video frame rendered');
      state = SimliState.rendering;
    };

    // Handle audio track settings based on the platform.
    if (kIsWeb) {
      stream.getAudioTracks().first.enabled = true;
    } else {
      stream.getAudioTracks().first.enabled = true;
      if (!Platform.isMacOS) {
        stream.getAudioTracks().first.enableSpeakerphone(true);
      }
    }
  }

  /// Closes the peer connection, data channels, and any active timers.
  ///
  /// This method ensures that all resources
  /// (e.g., data channels, peer connection,timers are properly disposed
  /// of when the client is no longer needed.
  Future<void> close() async {
    onDisconnected?.call();
    webSocket?.close();
    webSocket = null;
    if (peerConnection?.transceivers != null) {
      (await peerConnection?.getTransceivers())?.forEach(
        (transceiver) {
          transceiver.stop();
        },
      );
    }

    (await peerConnection?.senders)?.forEach((sender) {
      sender.track?.stop();
    });

    await peerConnection?.close();
    peerConnection = null;
    _stopAudioLevelChecking();
    videoRenderer?.dispose();
  }

  void _startAudioLevelChecking() {
    if (_audioStreamTack == null) return;
    monitorAudioPlaying(peerConnection!, _audioStreamTack!);
    return;
    audioLEvelTimer =
        Timer.periodic(const Duration(milliseconds: 125), (Timer timer) async {
      final stats = await peerConnection?.getStats(_audioStreamTack);
      if (stats != null) {
        for (final element in stats) {
          if (element.type == 'inbound-rtp' &&
              element.values['mediaType'].toString() == 'audio') {
            final audioLevelValue = element.values['audioLevel'];

            if (audioLevelValue != null) {
              final audioLevel = double.parse(audioLevelValue.toString());
              isSpeaking = audioLevel != 0;
              audioLevelNotifier.value = audioLevel;
            }
          }
        }
      }
    });
  }

  void _stopAudioLevelChecking() {
    audioLEvelTimer?.cancel();
    audioLEvelTimer = null;
  }

  Future<void> monitorAudioPlaying(
    RTCPeerConnection connection,
    MediaStreamTrack audioTrack,
  ) async {
    var silenceCounter = 0;
    audioLEvelTimer =
        Timer.periodic(clientConfig.audioCheckInterval, (timer) async {
      if (!audioTrack.enabled) {
        logException('The audio track is not playing (ended or disabled).');
        timer.cancel();
        return;
      }

      final stats = await connection.getStats(audioTrack);
      for (final report in stats) {
        if (report.type == 'inbound-rtp' &&
            report.values['mediaType'].toString() == 'audio') {
          final audioLevel = report.values['audioLevel'] as double? ?? 0.0;

          if (audioLevel > 0) {
            isSpeaking = true;
            silenceCounter = 0; // Reset silence counter
            // logInfo('SIMLI: Audio is playing.');
          } else {
            silenceCounter++;
            if (silenceCounter *
                    clientConfig.audioCheckInterval.inMilliseconds >=
                clientConfig.silenceThreshold.inMilliseconds) {
              isSpeaking = false;
              // logInfo('SIMLI: Audio is silent for a prolonged period.');
            }
          }
        }
      }
    });
  }

  ///it will clear the current audio buffer on server
  void clearBuffer() => webSocket?.send('SKIP');

  ///it will log using info method
  void logSuccess(dynamic data) {
    log.fine(data.toString());
  }

  ///it will log using info method
  void logInfo(dynamic data) {
    log.info(data.toString());
  }

  ///it will log using serve method
  void logException(dynamic data) {
    log.shout(data.toString());
  }
}
