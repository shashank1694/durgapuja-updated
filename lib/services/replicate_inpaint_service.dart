import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../config/api_keys.dart';

class ReplicateInpaintService {
  final String _apiKey = ApiKeys.replicateApiKey;
  final String _baseUrl = 'https://api.replicate.com/v1';

  /// Primary inpainting model on Replicate: FLUX.1 Fill [dev]
  static const String _fluxModelPath =
      '/models/black-forest-labs/flux-fill-dev/predictions';

  /// Fallback inpainting model: Stable Diffusion Inpainting
  static const String _sdInpaintModelPath =
      '/models/stability-ai/stable-diffusion-inpainting/predictions';

  Future<String> _prepareImageUrl(String imagePathOrUrl) async {
    if (imagePathOrUrl.startsWith('http://') ||
        imagePathOrUrl.startsWith('https://') ||
        imagePathOrUrl.startsWith('data:')) {
      return imagePathOrUrl;
    }
    final file = File(imagePathOrUrl);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    }
    return imagePathOrUrl;
  }

  /// Inpaints an image using the provided mask and prompt.
  Future<String> inpaintImage({
    required String originalImageUrl,
    required String maskImageUrl,
    required String prompt,
    int steps = 28,
    double guidance = 30.0,
  }) async {
    if (_apiKey.isEmpty) {
      throw Exception(
        'Replicate API key is missing. Please configure replicateApiKey in lib/config/api_keys.dart',
      );
    }

    try {
      final effectiveImageUrl = await _prepareImageUrl(originalImageUrl);
      final effectiveMaskUrl = await _prepareImageUrl(maskImageUrl);

      final url = Uri.parse('$_baseUrl$_fluxModelPath');
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Prefer': 'wait',
        },
        body: jsonEncode({
          'input': {
            'image': effectiveImageUrl,
            'mask': effectiveMaskUrl,
            'prompt': prompt,
            'guidance': guidance,
            'num_inference_steps': steps,
            'output_format': 'jpg',
          },
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final status = data['status'];

        if (status == 'succeeded') {
          return _extractOutputUrl(data['output']);
        }

        final predictionId = data['id'];
        return await _pollForCompletion(predictionId);
      } else if (response.statusCode == 404 || response.statusCode == 422) {
        // Fallback to SD inpainting if FLUX Fill is unavailable
        debugPrint(
          'FLUX Fill returned ${response.statusCode}, falling back to SD Inpainting...',
        );
        return await _runSdInpaint(
          imageUrl: effectiveImageUrl,
          maskUrl: effectiveMaskUrl,
          prompt: prompt,
        );
      } else {
        final body = response.body;
        String msg = 'Inpainting failed (${response.statusCode})';
        try {
          final err = jsonDecode(body);
          if (err is Map && (err['detail'] != null || err['message'] != null)) {
            msg =
                err['detail']?.toString() ?? err['message']?.toString() ?? msg;
          }
        } catch (_) {}
        throw Exception(msg);
      }
    } catch (e) {
      debugPrint('Replicate Inpainting failed: $e');
      throw Exception('Inpainting failed: $e');
    }
  }

  Future<String> _runSdInpaint({
    required String imageUrl,
    required String maskUrl,
    required String prompt,
  }) async {
    final url = Uri.parse('$_baseUrl$_sdInpaintModelPath');
    final response = await http.post(
      url,
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Prefer': 'wait',
      },
      body: jsonEncode({
        'input': {
          'image': imageUrl,
          'mask_image': maskUrl,
          'prompt': prompt,
          'num_inference_steps': 30,
        },
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body);
      if (data['status'] == 'succeeded') {
        return _extractOutputUrl(data['output']);
      }
      return await _pollForCompletion(data['id']);
    } else {
      throw Exception(
        'Inpainting service failed with status ${response.statusCode}',
      );
    }
  }

  String _extractOutputUrl(dynamic output) {
    if (output == null) throw Exception('No output received from inpainter');
    if (output is String && output.isNotEmpty) return output;
    if (output is List && output.isNotEmpty) {
      final first = output.first;
      if (first is String) return first;
      if (first is Map && first['image'] != null) {
        return first['image'].toString();
      }
      return first.toString();
    }
    if (output is Map) {
      for (final val in output.values) {
        if (val is String &&
            (val.startsWith('http://') || val.startsWith('https://'))) {
          return val;
        }
      }
    }
    throw Exception('Unrecognized inpainter output: $output');
  }

  Future<String> _pollForCompletion(String predictionId) async {
    final uri = Uri.parse('$_baseUrl/predictions/$predictionId');

    for (int i = 0; i < 60; i++) {
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['status'];

        if (status == 'succeeded') {
          return _extractOutputUrl(data['output']);
        } else if (status == 'failed' || status == 'canceled') {
          final error = data['error'] ?? 'Prediction failed or was canceled';
          throw Exception('Inpainting failed: $error');
        }
      } else {
        throw Exception(
          'Failed to check inpainting status: ${response.statusCode}',
        );
      }

      await Future.delayed(const Duration(milliseconds: 2000));
    }

    throw Exception('Inpainting timed out after 2 minutes');
  }
}
