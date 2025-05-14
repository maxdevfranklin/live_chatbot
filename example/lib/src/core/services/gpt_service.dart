import 'dart:developer';
import 'package:example/src/core/utils/api_keys.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class ChatGPTService {
  final String apiKey;
  final String model;
  String? sessionId;

  ChatGPTService(
      {this.apiKey = ApiKeys.gptApiKey, this.model = "gpt-3.5-turbo"}) {
    // Initialize session or any other setup if required
  }

  Future<ChatGPTAnswer> sendMsg({
    String text = "Hello, How are you?",
    String name = "Grace from 43rd Big Idea",
  }) async {
    final url = Uri.parse("https://api.openai.com/v1/chat/completions");
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    final payload = jsonEncode({
      "model": model,
      "messages": [
        {
          "role": "system",
          "content":
              "You are a helpful and friendly AI assistant named $name. Respond like a human with clear, specific answers. Keep responses under 120 characters."
        },
        {
          "role": "user",
          "content": text,
        }
      ],
      "max_tokens": 128,
      "n": 1,
      "stop": null,
    });

    try {
      final response = await http.post(url, headers: headers, body: payload);
      if (response.statusCode == 200) {
        final responseBody = jsonDecode(response.body);
        final content = responseBody['choices'][0]['message']['content'];
        log('Received response: $content');
        return ChatGPTAnswer.successful(content);
      } else {
        log('Error response from API: ${response.body}');
        return ChatGPTAnswer.failed(response.body);
      }
    } catch (error) {
      log('Request failed with error: $error');
      return ChatGPTAnswer.failed('Request failed with error: $error');
    }
  }
}

class ChatGPTAnswer {
  final bool isSuccessful;
  final String data;

  ChatGPTAnswer({
    required this.isSuccessful,
    required this.data,
  });

  factory ChatGPTAnswer.successful(String data) => ChatGPTAnswer(
        isSuccessful: true,
        data: data,
      );

  factory ChatGPTAnswer.failed(String data) => ChatGPTAnswer(
        isSuccessful: false,
        data: data,
      );

  Map<String, dynamic> toJson() => {
        "isSuccessful": isSuccessful,
        "data": data,
      };
}
