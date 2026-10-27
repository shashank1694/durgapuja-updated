import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../models/generated_image.dart';
import '../../models/editable_element.dart';
import '../config/api_keys.dart';
import 'replicate_sam_service.dart';
import 'replicate_inpaint_service.dart';
import 'krea_generative_fill_service.dart';
import 'krea_enhancement_service.dart';

class TapToEditService {
  final ReplicateSAMService _samService = ReplicateSAMService();
  final ReplicateInpaintService _inpaintService = ReplicateInpaintService();
  final KreaGenerativeFillService _kreaFillService =
      KreaGenerativeFillService();
  final KreaEnhancementService _kreaEnhanceService = KreaEnhancementService();

  /// Complete Tap-to-Edit workflow. Pass [traceImagePoints] (list of [x,y] in image coords)
  /// to improve detection of the region (face, weapons, ornaments, lion, etc.).
  /// If [precomputedMaskUrl] is provided (e.g. from the immediate edge-snapping preview),
  /// the SAM 2 step is skipped.
  Future<GeneratedImage> completeTapToEditWorkflow({
    required GeneratedImage originalImage,
    required double tapX,
    required double tapY,
    required double imageWidth,
    required double imageHeight,
    required String editPrompt,
    required ElementType elementType,
    List<List<double>>? traceImagePoints,
    String? precomputedMaskUrl,
    File? referenceImage,
    bool applyRelighting = false,
    bool preserveColors = true,
  }) async {
    try {
      final effectivePrompt = referenceImage != null
          ? 'Match the style, form and details of the reference image. $editPrompt'
          : editPrompt;

      // Step 1: Use precomputed mask if available, or generate via SAM 2
      String maskImageUrl;
      if (precomputedMaskUrl != null && precomputedMaskUrl.isNotEmpty) {
        maskImageUrl = precomputedMaskUrl;
      } else if (traceImagePoints != null && traceImagePoints.length >= 2) {
        maskImageUrl = await _samService.generateMaskFromPoints(
          imageUrl: originalImage.url,
          imagePoints: traceImagePoints,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
      } else {
        maskImageUrl = await _samService.generateMaskFromTap(
          imageUrl: originalImage.url,
          x: tapX,
          y: tapY,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
      }

      // Step 2: Apply generative fill using Replicate FLUX Fill (or SD Inpaint fallback)
      String editedImageUrl;
      try {
        editedImageUrl = await _inpaintService.inpaintImage(
          originalImageUrl: originalImage.url,
          maskImageUrl: maskImageUrl,
          prompt: effectivePrompt,
        );
      } catch (inpaintErr) {
        debugPrint(
          'Replicate inpaint failed: $inpaintErr, trying Krea fallback...',
        );
        editedImageUrl = await _kreaFillService.completeGenerativeFill(
          originalImageUrl: originalImage.url,
          maskImageUrl: maskImageUrl,
          prompt: effectivePrompt,
          referenceImage: referenceImage,
        );
      }

      // Step 3: Optional enhancement using Krea
      String finalImageUrl = editedImageUrl;
      if (applyRelighting && ApiKeys.kreaApiKey.isNotEmpty) {
        try {
          finalImageUrl = await _kreaEnhanceService.completeEnhancement(
            imageUrl: editedImageUrl,
            applyAutoEnhancement: true,
            applyProfessionalPolish: true,
          );
        } catch (enhanceErr) {
          debugPrint('Enhancement skipped: $enhanceErr');
          finalImageUrl = editedImageUrl;
        }
      }

      // Step 4: Create final edited image
      final editedImage = GeneratedImage(
        id: '${originalImage.id}_edited_${DateTime.now().millisecondsSinceEpoch}',
        url: finalImageUrl,
        prompt: originalImage.prompt,
        createdAt: DateTime.now(),
      );

      return editedImage;
    } catch (e) {
      debugPrint('Tap-to-Edit workflow failed: $e');
      throw Exception('Tap-to-Edit workflow failed: $e');
    }
  }

  /// Generate element-specific edit prompt
  String generateElementEditPrompt(
    ElementType elementType,
    String editDescription,
    String originalPrompt,
  ) {
    final elementDetails = EditableElement.fromType(elementType);

    return '''
Edit the ${elementDetails?.type.displayName.toLowerCase() ?? 'selected element'} of this Durga idol design:
Original design: $originalPrompt

Edit request: $editDescription

Requirements:
- Only modify the ${elementDetails?.type.displayName.toLowerCase() ?? 'selected element'}
- Keep all other elements exactly the same
- Maintain the overall composition and style
- Ensure seamless integration with existing elements
- Preserve the traditional Bengali Durga Puja aesthetic
- Focus specifically on: ${elementDetails?.description ?? 'the selected element'}
''';
  }

  /// Validate edit parameters
  bool validateEditParameters({
    required String editDescription,
    required double tapX,
    required double tapY,
    required double imageWidth,
    required double imageHeight,
  }) {
    // Check edit description
    if (editDescription.trim().isEmpty || editDescription.trim().length < 5) {
      return false;
    }

    // Check coordinates are within image bounds
    if (tapX < 0 || tapX > imageWidth || tapY < 0 || tapY > imageHeight) {
      return false;
    }

    return true;
  }

  /// Get element guidance for editing
  String getElementGuidance(ElementType elementType) {
    final element = EditableElement.fromType(elementType);
    return '''
Selected: ${element?.type.displayName ?? 'Element'}

${element?.description ?? 'Edit this element of your Durga idol design.'}

Tip: Be specific about what you want to change. For example:
- "Make the expression more serene"
- "Add more gold detailing to the jewelry"
- "Change the saree color to red and gold"
''';
  }

  /// Get example prompts for an element type
  List<String> getExamplePrompts(ElementType elementType) {
    final element = EditableElement.fromType(elementType);
    return element?.examplePrompts ?? [];
  }
}
