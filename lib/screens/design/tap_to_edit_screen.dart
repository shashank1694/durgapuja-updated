import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../models/generated_image.dart';
import '../../models/editable_element.dart';
import '../../services/tap_to_edit_service.dart';
import '../../services/replicate_sam_service.dart';
import '../../services/speech_service.dart';
import '../../services/language_service.dart';
import '../../utils/colors.dart';
import '../../utils/constants.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/voice_input_button.dart';
import '../../widgets/language_toggle_action.dart';

class TapToEditScreen extends StatefulWidget {
  final GeneratedImage? image;

  const TapToEditScreen({Key? key, this.image}) : super(key: key);

  @override
  State<TapToEditScreen> createState() => _TapToEditScreenState();
}

class _TapToEditScreenState extends State<TapToEditScreen>
    with TickerProviderStateMixin {
  final TapToEditService _tapToEditService = TapToEditService();
  final ReplicateSAMService _samService = ReplicateSAMService();
  final SpeechService _speechService = SpeechService();
  final TextEditingController _promptController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  // Interactive zoom & snapping controllers
  late final TransformationController _transformationController;
  late final AnimationController _zoomAnimationController;
  Animation<Matrix4>? _zoomAnimation;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  double _currentScale = 1.0;
  bool _isSnapping = false;
  String? _maskImageUrl;
  Offset? _lastTapFocusPoint;

  GeneratedImage? _currentImage;
  bool _isEditing = false;
  bool _showEditPanel = false;
  bool _showImageSourceOptions = false;
  bool _isTracing = false;
  bool _showConfirmSelection = false;

  // Freehand tracing state
  List<Offset> _tracePoints = [];
  List<List<Offset>> _completedTraces = [];
  Path? _currentTracePath;

  double _imageWidth = 0;
  double _imageHeight = 0;
  Offset _imageOffset = Offset
      .zero; // Image top-left in container space for coordinate conversion
  ElementType? _selectedElementType;
  final GlobalKey _imageKey = GlobalKey();
  final GlobalKey _containerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _currentImage = widget.image;

    _transformationController = TransformationController();
    _transformationController.addListener(_onTransformationChanged);

    _zoomAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _zoomAnimationController.addListener(() {
      if (_zoomAnimation != null) {
        _transformationController.value = _zoomAnimation!.value;
      }
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Get image dimensions after the frame is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _getImageDimensions();
    });
  }

  void _onTransformationChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - _currentScale).abs() > 0.05) {
      setState(() {
        _currentScale = scale;
      });
    }
  }

  void _getImageDimensions() {
    final imageBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    final containerBox =
        _containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (imageBox != null && containerBox != null) {
      setState(() {
        _imageWidth = imageBox.size.width;
        _imageHeight = imageBox.size.height;
        final imageGlobal = imageBox.localToGlobal(Offset.zero);
        _imageOffset = containerBox.globalToLocal(imageGlobal);
      });
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformationChanged);
    _transformationController.dispose();
    _zoomAnimationController.dispose();
    _pulseController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _startVoiceInput() async {
    if (!_speechService.isListening) {
      final started = await _speechService.startListening();
      if (mounted) setState(() {});
      if (!started) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                Provider.of<LanguageService>(
                  context,
                  listen: false,
                ).getText('voice_input_failed'),
              ),
            ),
          );
        }
      }
      return;
    }
    final text = await _speechService.stopListening();
    if (mounted) {
      setState(() {
        if (text.isNotEmpty) _promptController.text = text;
      });
    }
  }

  Future<void> _selectImageSource() async {
    setState(() {
      _showImageSourceOptions = true;
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    setState(() {
      _showImageSourceOptions = false;
    });

    try {
      final pickedFile = await _picker.pickImage(source: source);
      if (pickedFile != null) {
        setState(() {
          _currentImage = GeneratedImage(
            id: 'gallery_${DateTime.now().millisecondsSinceEpoch}',
            url: pickedFile.path,
            prompt: 'User uploaded image',
            createdAt: DateTime.now(),
          );
          // Reset selection
          _resetSelection();
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to pick image: $e')));
    }
  }

  void _resetSelection() {
    _tracePoints.clear();
    _completedTraces.clear();
    _currentTracePath = null;
    _isTracing = false;
    _isSnapping = false;
    _maskImageUrl = null;
    _lastTapFocusPoint = null;
    _showEditPanel = false;
    _selectedElementType = null;
    _promptController.clear();
  }

  /// Calculates zoom scale based on selection size to nicely frame the element
  double _calculateAdaptiveScale({
    required double boxWidth,
    required double boxHeight,
    required Size viewportSize,
  }) {
    if (boxWidth <= 40 || boxHeight <= 40) {
      // Single tap or tiny selection -> 2.5x as requested by user
      return 2.5;
    }
    // Make selection fill roughly 65% of viewport
    final scaleX = (viewportSize.width * 0.65) / boxWidth;
    final scaleY = (viewportSize.height * 0.65) / boxHeight;
    final scale = math.min(scaleX, scaleY);
    return scale.clamp(1.5, 4.0);
  }

  /// Smoothly animates the viewport to focus on the target point
  void _animateZoomTo({
    required Offset focusPoint,
    required double targetScale,
  }) {
    final containerBox =
        _containerKey.currentContext?.findRenderObject() as RenderBox?;
    final viewportSize = containerBox?.size ?? MediaQuery.of(context).size;
    final vw = viewportSize.width;
    final vh = viewportSize.height;

    // Center focusPoint in viewport when scaled
    final tx = vw / 2 - focusPoint.dx * targetScale;
    final ty = vh / 2 - focusPoint.dy * targetScale;

    final targetMatrix = Matrix4.identity()
      ..translate(tx, ty)
      ..scale(targetScale);

    _zoomAnimationController.stop();
    _zoomAnimation =
        Matrix4Tween(
          begin: _transformationController.value,
          end: targetMatrix,
        ).animate(
          CurvedAnimation(
            parent: _zoomAnimationController,
            curve: Curves.easeOutCubic,
          ),
        );

    _zoomAnimationController.reset();
    _zoomAnimationController.forward();
  }

  /// Reset view back to 1.0x scale
  void _resetZoom() {
    _zoomAnimationController.stop();
    _zoomAnimation =
        Matrix4Tween(
          begin: _transformationController.value,
          end: Matrix4.identity(),
        ).animate(
          CurvedAnimation(
            parent: _zoomAnimationController,
            curve: Curves.easeOutCubic,
          ),
        );
    _zoomAnimationController.reset();
    _zoomAnimationController.forward();
  }

  /// Calls Meta's SAM 2 to automatically snap to object edges
  Future<void> _triggerEdgeSnapping({
    required double tapX,
    required double tapY,
    List<List<double>>? traceImagePoints,
  }) async {
    if (_currentImage == null) return;

    setState(() {
      _isSnapping = true;
      _maskImageUrl = null;
    });

    try {
      final imgW = _imageWidth > 0 ? _imageWidth : 512.0;
      final imgH = _imageHeight > 0 ? _imageHeight : 512.0;

      String maskUrl;
      if (traceImagePoints != null && traceImagePoints.length >= 2) {
        maskUrl = await _samService.generateMaskFromPoints(
          imageUrl: _currentImage!.url,
          imagePoints: traceImagePoints,
          imageWidth: imgW,
          imageHeight: imgH,
        );
      } else {
        maskUrl = await _samService.generateMaskFromTap(
          imageUrl: _currentImage!.url,
          x: tapX,
          y: tapY,
          imageWidth: imgW,
          imageHeight: imgH,
        );
      }

      if (mounted) {
        setState(() {
          _maskImageUrl = maskUrl;
          _isSnapping = false;
          _showConfirmSelection = true;
        });
        HapticFeedback.mediumImpact();
      }
    } catch (e) {
      debugPrint('SAM 2 edge snapping failed: $e');
      if (mounted) {
        setState(() {
          _isSnapping = false;
          _showConfirmSelection = true; // Still allow manual trace fallback
        });
      }
    }
  }

  void _handlePanStart(DragStartDetails details) {
    if (_currentImage == null || _isEditing) return;

    final RenderBox? containerBox =
        _containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (containerBox == null) return;

    final Offset localOffset = containerBox.globalToLocal(
      details.globalPosition,
    );

    HapticFeedback.selectionClick();

    setState(() {
      _tracePoints = [localOffset];
      _isTracing = true;
      _showEditPanel = false;
      _showConfirmSelection = false;
      _maskImageUrl = null;
      _currentTracePath = Path()..moveTo(localOffset.dx, localOffset.dy);
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!_isTracing) return;

    final RenderBox? containerBox =
        _containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (containerBox == null) return;

    final Offset localOffset = containerBox.globalToLocal(
      details.globalPosition,
    );
    const double minPointDistance = 3.0;
    if (_tracePoints.isEmpty ||
        (localOffset - _tracePoints.last).distance > minPointDistance) {
      setState(() {
        _tracePoints.add(localOffset);
        _currentTracePath?.lineTo(localOffset.dx, localOffset.dy);
      });
    }
  }

  void _handlePanEnd(DragEndDetails details) {
    if (!_isTracing) return;

    setState(() {
      _isTracing = false;
      if (_tracePoints.length >= 8) {
        final smoothed = _smoothTrace(_tracePoints);
        _completedTraces = [smoothed];
        _currentTracePath = null;

        // Calculate bounding box and center
        final minX = smoothed.map((p) => p.dx).reduce(math.min);
        final maxX = smoothed.map((p) => p.dx).reduce(math.max);
        final minY = smoothed.map((p) => p.dy).reduce(math.min);
        final maxY = smoothed.map((p) => p.dy).reduce(math.max);
        final boxW = maxX - minX;
        final boxH = maxY - minY;
        final centerX = (minX + maxX) / 2;
        final centerY = (minY + maxY) / 2;

        final containerBox =
            _containerKey.currentContext?.findRenderObject() as RenderBox?;
        final vpSize = containerBox?.size ?? MediaQuery.of(context).size;
        final scale = _calculateAdaptiveScale(
          boxWidth: boxW,
          boxHeight: boxH,
          viewportSize: vpSize,
        );

        _lastTapFocusPoint = Offset(centerX, centerY);
        _animateZoomTo(
          focusPoint: Offset(centerX, centerY),
          targetScale: scale,
        );

        // Convert points to image space for SAM 2
        final imgW = _imageWidth > 0 ? _imageWidth : 512.0;
        final imgH = _imageHeight > 0 ? _imageHeight : 512.0;
        final imagePoints = smoothed.map((p) {
          final ix = (p.dx - _imageOffset.dx).clamp(0.0, imgW);
          final iy = (p.dy - _imageOffset.dy).clamp(0.0, imgH);
          return [ix, iy];
        }).toList();

        final centerTapX = (centerX - _imageOffset.dx).clamp(0.0, imgW);
        final centerTapY = (centerY - _imageOffset.dy).clamp(0.0, imgH);

        _triggerEdgeSnapping(
          tapX: centerTapX,
          tapY: centerTapY,
          traceImagePoints: imagePoints,
        );
      } else {
        _resetSelection();
      }
    });
  }

  void _handleTap(TapDownDetails details) {
    if (_currentImage == null || _isEditing) return;

    final RenderBox? containerBox =
        _containerKey.currentContext?.findRenderObject() as RenderBox?;
    if (containerBox == null) return;

    final Offset localOffset = containerBox.globalToLocal(
      details.globalPosition,
    );

    HapticFeedback.selectionClick();

    const double r = 28.0;
    final tapPoints = [
      localOffset + const Offset(r, 0),
      localOffset + Offset(r * 0.7, r * 0.7),
      localOffset + const Offset(0, r),
      localOffset + Offset(-r * 0.7, r * 0.7),
      localOffset + const Offset(-r, 0),
      localOffset + Offset(-r * 0.7, -r * 0.7),
      localOffset + const Offset(0, -r),
      localOffset + Offset(r * 0.7, -r * 0.7),
      localOffset + const Offset(r, 0),
    ];

    setState(() {
      _tracePoints = tapPoints;
      _completedTraces = [tapPoints];
      _lastTapFocusPoint = localOffset;
    });

    // Animate zoom to tap point at 2.5x
    _animateZoomTo(focusPoint: localOffset, targetScale: 2.5);

    // Calculate image space coordinates for SAM 2
    final imgW = _imageWidth > 0 ? _imageWidth : 512.0;
    final imgH = _imageHeight > 0 ? _imageHeight : 512.0;
    final tapX = (localOffset.dx - _imageOffset.dx).clamp(0.0, imgW);
    final tapY = (localOffset.dy - _imageOffset.dy).clamp(0.0, imgH);

    _triggerEdgeSnapping(tapX: tapX, tapY: tapY);
  }

  /// Smooth trace with a simple 3-point moving average for cleaner identification.
  List<Offset> _smoothTrace(List<Offset> points) {
    if (points.length < 4) return List.from(points);
    final smoothed = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      final prev = points[math.max(0, i - 1)];
      final curr = points[i];
      final next = points[math.min(points.length - 1, i + 1)];
      smoothed.add(
        Offset(
          (prev.dx + curr.dx + next.dx) / 3,
          (prev.dy + curr.dy + next.dy) / 3,
        ),
      );
    }
    return smoothed;
  }

  void _confirmSelection() {
    setState(() {
      _showConfirmSelection = false;
      _showEditPanel = true;
    });
  }

  void _cancelSelection() {
    setState(() {
      _showConfirmSelection = false;
      _resetSelection();
    });
  }

  Future<void> _applyEdit() async {
    if (_currentImage == null ||
        _completedTraces.isEmpty ||
        _selectedElementType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageService>(
              context,
              listen: false,
            ).getText('please_trace_and_select'),
          ),
        ),
      );
      return;
    }

    final editDescription = _promptController.text.trim();
    if (editDescription.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Provider.of<LanguageService>(
              context,
              listen: false,
            ).getText('please_describe_changes'),
          ),
        ),
      );
      return;
    }

    setState(() {
      _isEditing = true;
    });

    try {
      final imgW = _imageWidth > 0 ? _imageWidth : 512.0;
      final imgH = _imageHeight > 0 ? _imageHeight : 512.0;

      // Bounding box of traced area (in container space)
      final allPoints = _completedTraces.expand((trace) => trace).toList();
      final minX = allPoints.map((p) => p.dx).reduce(math.min);
      final maxX = allPoints.map((p) => p.dx).reduce(math.max);
      final minY = allPoints.map((p) => p.dy).reduce(math.min);
      final maxY = allPoints.map((p) => p.dy).reduce(math.max);
      final centerX = (minX + maxX) / 2;
      final centerY = (minY + maxY) / 2;

      // Convert center to image space for SAM
      final tapX = (centerX - _imageOffset.dx).clamp(0.0, imgW);
      final tapY = (centerY - _imageOffset.dy).clamp(0.0, imgH);

      // Convert trace points to image space for SAM
      List<List<double>>? tracePointsForSAM;
      if (_completedTraces.isNotEmpty && _completedTraces.first.length >= 2) {
        tracePointsForSAM = _completedTraces.first.map((p) {
          final ix = (p.dx - _imageOffset.dx).clamp(0.0, imgW);
          final iy = (p.dy - _imageOffset.dy).clamp(0.0, imgH);
          return [ix, iy];
        }).toList();
      }

      final editPrompt = _tapToEditService.generateElementEditPrompt(
        _selectedElementType!,
        editDescription,
        _currentImage!.prompt,
      );

      final editedImage = await _tapToEditService.completeTapToEditWorkflow(
        originalImage: _currentImage!,
        tapX: tapX,
        tapY: tapY,
        imageWidth: imgW,
        imageHeight: imgH,
        editPrompt: editPrompt,
        elementType: _selectedElementType!,
        precomputedMaskUrl: _maskImageUrl,
        traceImagePoints: tracePointsForSAM,
      );

      setState(() {
        _currentImage = editedImage;
        _resetSelection();
        _isEditing = false;
      });

      // Show success dialog with option to view the edited image
      await _showEditSuccessDialog(editedImage);
    } catch (e) {
      setState(() {
        _isEditing = false;
      });
      final msg = _sanitizeErrorMessage(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Edit failed: $msg'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  /// Never show raw HTML or huge error dumps to the user.
  String _sanitizeErrorMessage(Object e) {
    final s = e.toString();
    if (s.contains('<html') ||
        s.contains('<!doctype') ||
        s.contains('<title')) {
      return 'Server returned an error. Check API keys and try again.';
    }
    if (s.length > 200) return '${s.substring(0, 197)}...';
    return s.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<LanguageService>();
    return Scaffold(
      backgroundColor: AppColors.backgroundCream,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (widget.image != null && context.canPop()) {
              context.pop();
            } else {
              context.go('/design/welcome');
            }
          },
          tooltip: lang.getText('back'),
        ),
        title: Text(lang.getText('tap_to_edit_title')),
        actions: [
          const LanguageToggleAction(),
          if (_completedTraces.isNotEmpty || _currentTracePath != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _resetSelection,
              tooltip: lang.getText('clear_selection'),
            ),
          IconButton(
            icon: const Icon(Icons.image),
            onPressed: _selectImageSource,
            tooltip: lang.getText('select_image'),
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(lang.getText('image_saved'))),
              );
            },
            tooltip: lang.getText('save'),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Image Viewer (ignore pointer when overlay or edit panel is shown so buttons work)
            IgnorePointer(
              ignoring: _showConfirmSelection || _showEditPanel,
              child: _buildImageViewer(context),
            ),

            // Image Source Options
            if (_showImageSourceOptions) _buildImageSourceOptions(context),

            // Confirm Selection Overlay (positioned above navbar so it's visible and tappable)
            if (_showConfirmSelection) _buildConfirmSelectionOverlay(context),

            // Edit Panel
            if (_showEditPanel) _buildEditPanel(context),

            // Loading Overlay
            if (_isEditing) _buildLoadingOverlay(),

            // Instructions
            if (_currentImage != null &&
                _completedTraces.isEmpty &&
                _currentTracePath == null &&
                !_showEditPanel)
              _buildInstructions(),
          ],
        ),
      ),
    );
  }

  /// Returns true if [url] is a local file path (e.g. from gallery picker).
  bool _isLocalFilePath(String url) {
    return url.startsWith('/') ||
        url.startsWith('file:') ||
        (!url.startsWith('http://') && !url.startsWith('https://'));
  }

  Widget _buildImageWidget() {
    final url = _currentImage!.url;
    if (_isLocalFilePath(url)) {
      final file = File(url);
      if (!file.existsSync()) {
        return Container(
          color: Colors.black,
          child: const Center(
            child: Icon(Icons.broken_image, size: 48, color: Colors.white),
          ),
        );
      }
      return Image.file(
        file,
        fit: BoxFit.contain,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _getImageDimensions();
            });
          }
          return child;
        },
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Icon(Icons.broken_image, size: 48, color: Colors.white),
            ),
          );
        },
      );
    }
    return Image.network(
      url,
      fit: BoxFit.contain,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _getImageDimensions();
          });
          return child;
        }
        return const Center(
          child: CircularProgressIndicator(color: AppColors.primaryBrown),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.black,
          child: const Center(
            child: Icon(Icons.broken_image, size: 48, color: Colors.white),
          ),
        );
      },
    );
  }

  Widget _buildImageViewer(BuildContext context) {
    final lang = context.watch<LanguageService>();
    return Container(
      key: _containerKey,
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Pinchable, zoomable InteractiveViewer
          InteractiveViewer(
            transformationController: _transformationController,
            minScale: 1.0,
            maxScale: 5.0,
            panEnabled: true,
            scaleEnabled: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _handlePanStart,
              onPanUpdate: _handlePanUpdate,
              onPanEnd: _handlePanEnd,
              onTapDown: _handleTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Base image
                  if (_currentImage != null)
                    Center(
                      child: FittedBox(
                        key: _imageKey,
                        fit: BoxFit.contain,
                        child: _buildImageWidget(),
                      ),
                    )
                  else
                    Container(
                      color: Colors.black,
                      child: Center(
                        child: Text(
                          lang.getText('no_image_selected'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppConstants.fontSizeLarge,
                          ),
                        ),
                      ),
                    ),

                  // SAM 2 Edge-Snapped Mask Overlay (golden amber glowing highlight)
                  if (_maskImageUrl != null &&
                      _imageWidth > 0 &&
                      _imageHeight > 0)
                    Center(
                      child: SizedBox(
                        width: _imageWidth,
                        height: _imageHeight,
                        child: ColorFiltered(
                          colorFilter: const ColorFilter.matrix(<double>[
                            1.0,
                            0,
                            0,
                            0,
                            0,
                            0.42,
                            0,
                            0,
                            0,
                            0,
                            0.21,
                            0,
                            0,
                            0,
                            0,
                            0.55,
                            0,
                            0,
                            0,
                            0,
                          ]),
                          child: Image.network(
                            _maskImageUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox(),
                          ),
                        ),
                      ),
                    ),

                  // Freehand Tracing / Circular Tap Overlay
                  if (_completedTraces.isNotEmpty || _currentTracePath != null)
                    CustomPaint(
                      painter: TracingPainter(
                        completedTraces: _completedTraces,
                        currentTrace: _currentTracePath,
                        isTracing: _isTracing,
                      ),
                      child: Container(),
                    ),

                  // Pulsing ripple ring while SAM 2 snaps to edges
                  if (_isSnapping && _lastTapFocusPoint != null)
                    Positioned(
                      left: _lastTapFocusPoint!.dx - 36,
                      top: _lastTapFocusPoint!.dy - 36,
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: _pulseAnimation.value,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.accentOrange,
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.accentOrange.withOpacity(
                                      0.5,
                                    ),
                                    blurRadius: 16,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Floating Reset Zoom Button when zoomed in
          if (_currentScale > 1.1)
            Positioned(
              top: 70,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _resetZoom,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.zoom_out_map,
                          color: Colors.white,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_currentScale.toStringAsFixed(1)}x  Reset',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Snapping in progress indicator pill
          if (_isSnapping)
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.accentOrange.withOpacity(0.6),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accentOrange,
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'AI snapping to element edges...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConfirmSelectionOverlay(BuildContext context) {
    final lang = context.watch<LanguageService>();
    const double navBarClearance = 100;
    return Positioned(
      bottom: navBarClearance,
      left: 20,
      right: 20,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(AppConstants.mediumPadding),
          decoration: BoxDecoration(
            color: AppColors.cardCream,
            borderRadius: BorderRadius.circular(AppConstants.borderRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_maskImageUrl != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.accentOrange.withOpacity(0.4),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: AppColors.accentOrange,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'AI Snapped to Element Edges',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accentOrange,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                _maskImageUrl != null
                    ? 'Element Edges Detected'
                    : lang.getText('tracing_confirmed'),
                style: TextStyle(
                  fontSize: AppConstants.fontSizeMedium,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _maskImageUrl != null
                    ? 'Highlighted area will be edited. Pinch to adjust view or proceed.'
                    : lang.getText('element_traced_ready'),
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textLight,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: CustomButton(
                      onPressed: _cancelSelection,
                      label: lang.getText('cancel'),
                      backgroundColor: AppColors.textLight,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CustomButton(
                      onPressed: _confirmSelection,
                      label: lang.getText('confirm_selection'),
                      icon: Icons.check,
                      backgroundColor: AppColors.accentOrange,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstructions() {
    return Positioned(
      top: 20,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.7),
          borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        ),
        child: Row(
          children: [
            Icon(Icons.touch_app, color: AppColors.accentOrange, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Trace around the element you want to edit with your finger',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppConstants.fontSizeSmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSourceOptions(BuildContext context) {
    final lang = context.watch<LanguageService>();
    return Positioned(
      bottom: 20,
      left: 20,
      right: 20,
      child: Container(
        padding: const EdgeInsets.all(AppConstants.mediumPadding),
        decoration: BoxDecoration(
          color: AppColors.cardCream,
          borderRadius: BorderRadius.circular(AppConstants.borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              lang.getText('select_image_source'),
              style: TextStyle(
                fontSize: AppConstants.fontSizeMedium,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: CustomButton(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    label: lang.getText('gallery'),
                    icon: Icons.photo_library,
                    backgroundColor: AppColors.primaryBrown,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CustomButton(
                    onPressed: () => _pickImage(ImageSource.camera),
                    label: lang.getText('camera'),
                    icon: Icons.camera_alt,
                    backgroundColor: AppColors.accentOrange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CustomButton(
              onPressed: () {
                setState(() {
                  _showImageSourceOptions = false;
                });
              },
              label: lang.getText('cancel'),
              backgroundColor: AppColors.textLight,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditPanel(BuildContext context) {
    final lang = context.watch<LanguageService>();
    EditableElement.fromType(_selectedElementType ?? ElementType.face);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        padding: const EdgeInsets.all(AppConstants.mediumPadding),
        decoration: BoxDecoration(
          color: AppColors.cardCream,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppConstants.borderRadius),
            topRight: Radius.circular(AppConstants.borderRadius),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(
            bottom: 100,
          ), // Added bottom padding to prevent navbar overlap
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textLight.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // Element Selection (only show if not auto-detected)
              if (_selectedElementType == null)
                Column(
                  children: [
                    Text(
                      lang.getText('select_element_to_edit_short'),
                      style: TextStyle(
                        fontSize: AppConstants.fontSizeMedium,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: ElementType.values.map((elementType) {
                        return FilterChip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_getIconForType(elementType), size: 16),
                              const SizedBox(width: 4),
                              Text(elementType.displayName),
                            ],
                          ),
                          selected: _selectedElementType == elementType,
                          selectedColor: AppColors.accentOrange.withOpacity(
                            0.3,
                          ),
                          onSelected: (selected) {
                            if (selected) {
                              setState(() {
                                _selectedElementType = elementType;
                              });
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                )
              else
                // Auto-detected element info
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(
                      AppConstants.borderRadius,
                    ),
                    border: Border.all(
                      color: AppColors.accentOrange.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _getIconForType(_selectedElementType!),
                        size: 20,
                        color: AppColors.accentOrange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${lang.getText('selected')}: ${_selectedElementType!.displayName}',
                          style: TextStyle(
                            fontSize: AppConstants.fontSizeSmall,
                            color: AppColors.textDark,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 16),
                        onPressed: () {
                          setState(() {
                            _selectedElementType = null;
                          });
                        },
                        tooltip: lang.getText('change_selection'),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),

              // Guidance Text
              if (_selectedElementType != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentOrange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(
                      AppConstants.borderRadius,
                    ),
                    border: Border.all(
                      color: AppColors.accentOrange.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        size: 20,
                        color: AppColors.accentOrange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tapToEditService.getElementGuidance(
                            _selectedElementType!,
                          ),
                          style: TextStyle(
                            fontSize: AppConstants.fontSizeSmall,
                            color: AppColors.textDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),

              // Prompt Input
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(
                    AppConstants.borderRadius,
                  ),
                  border: Border.all(
                    color: AppColors.primaryBrown.withOpacity(0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _promptController,
                        maxLines: 3,
                        minLines: 2,
                        style: TextStyle(fontSize: AppConstants.fontSizeMedium),
                        decoration: InputDecoration(
                          hintText: _selectedElementType != null
                              ? 'Describe changes for ${_selectedElementType!.displayName.toLowerCase()}...'
                              : 'Select an element type first',
                          hintStyle: TextStyle(color: AppColors.textLight),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: VoiceInputButton(
                        onPressed: _startVoiceInput,
                        isListening: _speechService.isListening,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Example Prompts
              if (_selectedElementType != null &&
                  _tapToEditService
                      .getExamplePrompts(_selectedElementType!)
                      .isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Example Prompts:',
                      style: TextStyle(
                        fontSize: AppConstants.fontSizeSmall,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _tapToEditService
                          .getExamplePrompts(_selectedElementType!)
                          .map((prompt) {
                            return InkWell(
                              onTap: () {
                                setState(() {
                                  _promptController.text = prompt;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: AppColors.primaryBrown.withOpacity(
                                      0.3,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  prompt,
                                  style: TextStyle(
                                    fontSize: AppConstants.fontSizeSmall,
                                    color: AppColors.textDark,
                                  ),
                                ),
                              ),
                            );
                          })
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: CustomButton(
                      onPressed: _resetSelection,
                      label: lang.getText('cancel'),
                      backgroundColor: AppColors.textLight,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: CustomButton(
                      onPressed: _applyEdit,
                      label: lang.getText('apply_edit'),
                      icon: Icons.auto_fix_high,
                      backgroundColor: AppColors.accentOrange,
                      isLoading: _isEditing,
                    ),
                  ),
                ],
              ),

              // Success Indicator
              if (_currentImage != null &&
                  _currentImage!.id != widget.image?.id)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accentOrange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(
                        AppConstants.borderRadius,
                      ),
                      border: Border.all(
                        color: AppColors.accentOrange.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          size: 20,
                          color: AppColors.accentOrange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            lang.getText('image_edited_view_above'),
                            style: TextStyle(
                              fontSize: AppConstants.fontSizeSmall,
                              color: AppColors.textDark,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Additional content to ensure the page is scrollable and buttons are accessible
              const SizedBox(height: 40),
              _buildAccessibilityInfo(),
              const SizedBox(height: 60),
              _buildAdditionalContent(),
              const SizedBox(
                height: 80,
              ), // Extra padding to ensure buttons are accessible
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccessibilityInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentOrange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        border: Border.all(color: AppColors.accentOrange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.accessibility, color: AppColors.accentOrange),
              const SizedBox(width: 8),
              Text(
                'Accessibility Tips',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeMedium,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'If you\'re having trouble accessing the Apply Edit button, try scrolling down the edit panel. The buttons are positioned at the bottom to ensure they\'re accessible even when navigation bars are present.',
            style: TextStyle(
              fontSize: AppConstants.fontSizeSmall,
              color: AppColors.textDark,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.touch_app, size: 16, color: AppColors.accentOrange),
              const SizedBox(width: 8),
              Text(
                'Scroll down to access the Apply Edit button',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.arrow_downward,
                size: 16,
                color: AppColors.accentOrange,
              ),
              const SizedBox(width: 8),
              Text(
                'The edit panel is designed to be scrollable for better accessibility',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAdditionalContent() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        border: Border.all(color: AppColors.primaryBrown.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: AppColors.accentOrange),
              const SizedBox(width: 8),
              Text(
                'Edit Tips',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeMedium,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'For best editing results:',
            style: TextStyle(
              fontSize: AppConstants.fontSizeSmall,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.circle, size: 6, color: AppColors.accentOrange),
              const SizedBox(width: 12),
              Text(
                'Be specific about what you want to change',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.circle, size: 6, color: AppColors.accentOrange),
              const SizedBox(width: 12),
              Text(
                'Use clear, descriptive language',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.circle, size: 6, color: AppColors.accentOrange),
              const SizedBox(width: 12),
              Text(
                'Consider the element type you selected',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.circle, size: 6, color: AppColors.accentOrange),
              const SizedBox(width: 12),
              Text(
                'Use example prompts as inspiration',
                style: TextStyle(
                  fontSize: AppConstants.fontSizeSmall,
                  color: AppColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Tip: The more precise your description, the better the AI can make your edits!',
            style: TextStyle(
              fontSize: AppConstants.fontSizeSmall,
              color: AppColors.textDark,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.7),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: AppColors.accentOrange),
            const SizedBox(height: AppConstants.mediumPadding),
            Text(
              'Processing your edit...',
              style: TextStyle(
                color: Colors.white,
                fontSize: AppConstants.fontSizeLarge,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppConstants.smallPadding),
            Text(
              'This may take a moment',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIconForType(ElementType elementType) {
    switch (elementType) {
      case ElementType.face:
        return Icons.face;
      case ElementType.jewelry:
        return Icons.diamond;
      case ElementType.clothing:
        return Icons.checkroom;
      case ElementType.weapon:
        return Icons.extension;
      case ElementType.ornaments:
      case ElementType.ornament:
        return Icons.diamond;
      case ElementType.pose:
        return Icons.accessibility;
      case ElementType.background:
        return Icons.photo;
      case ElementType.lighting:
        return Icons.lightbulb;
      case ElementType.lion:
        return Icons.pets;
    }
  }

  Future<void> _showEditSuccessDialog(GeneratedImage editedImage) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Edit Complete!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Your image has been successfully edited.'),
              const SizedBox(height: 16),
              const Text(
                'You can now view the edited image in the viewer above.',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

/// Custom painter for drawing freehand tracing overlay with clear identification
class TracingPainter extends CustomPainter {
  final List<List<Offset>> completedTraces;
  final Path? currentTrace;
  final bool isTracing;

  TracingPainter({
    required this.completedTraces,
    required this.currentTrace,
    required this.isTracing,
  });

  static const double _strokeWidth = 4.0;
  static const double _glowWidth = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Draw completed traces
    for (final trace in completedTraces) {
      if (trace.length < 2) continue;

      final path = Path();
      path.moveTo(trace.first.dx, trace.first.dy);
      for (int i = 1; i < trace.length; i++) {
        path.lineTo(trace[i].dx, trace[i].dy);
      }
      path.close();

      // Dark overlay outside the traced area (dimmer for clearer focus on selection)
      final overlayPaint = Paint()
        ..color = Colors.black.withOpacity(0.55)
        ..style = PaintingStyle.fill;

      final combinedPath = Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addPath(path, Offset.zero)
        ..fillType = PathFillType.evenOdd;

      canvas.drawPath(combinedPath, overlayPaint);

      // Fill the traced area first so border sits on top
      final fillPaint = Paint()
        ..color = AppColors.accentOrange.withOpacity(0.25)
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, fillPaint);

      // Subtle glow behind border for better visibility
      final glowPaint = Paint()
        ..color = AppColors.accentOrange.withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _glowWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, glowPaint);

      // Trace border — rounded for smoother identification
      final borderPaint = Paint()
        ..color = AppColors.accentOrange
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, borderPaint);
    }

    // Draw current trace being drawn
    if (currentTrace != null) {
      // Dashed border while drawing (rounded)
      final dashPath = _createDashedPath(currentTrace!, 12.0, 6.0);
      final borderPaint = Paint()
        ..color = AppColors.accentOrange
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(dashPath, borderPaint);

      // Current position indicator (larger for visibility)
      final metrics = currentTrace!.computeMetrics().toList();
      if (metrics.isNotEmpty) {
        final lastMetric = metrics.last;
        final pos = lastMetric.getTangentForOffset(lastMetric.length)?.position;

        if (pos != null) {
          final centerPaint = Paint()
            ..color = AppColors.accentOrange
            ..style = PaintingStyle.fill;
          canvas.drawCircle(pos, 8, centerPaint);

          final centerBorderPaint = Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5;
          canvas.drawCircle(pos, 8, centerBorderPaint);
        }
      }
    }
  }

  Path _createDashedPath(Path path, double dashLength, double dashSpace) {
    final metrics = path.computeMetrics();
    final newPath = Path();

    for (final metric in metrics) {
      double distance = 0;
      bool draw = true;

      while (distance < metric.length) {
        if (draw) {
          final startTangent = metric.getTangentForOffset(distance);
          final endTangent = metric.getTangentForOffset(distance + dashLength);

          if (startTangent != null && endTangent != null) {
            newPath.moveTo(startTangent.position.dx, startTangent.position.dy);
            newPath.lineTo(endTangent.position.dx, endTangent.position.dy);
          }
        }

        distance += dashLength + dashSpace;
        draw = !draw;
      }
    }

    return newPath;
  }

  @override
  bool shouldRepaint(TracingPainter oldDelegate) {
    return oldDelegate.completedTraces != completedTraces ||
        oldDelegate.currentTrace != currentTrace ||
        oldDelegate.isTracing != isTracing;
  }
}

/// Custom painter for drawing the circle selection overlay (legacy)
class CircleSelectionPainter extends CustomPainter {
  final Offset center;
  final double radius;
  final bool isDrawing;

  CircleSelectionPainter({
    required this.center,
    required this.radius,
    this.isDrawing = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Dark overlay outside the circle
    final overlayPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    final circlePath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCircle(center: center, radius: radius))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(circlePath, overlayPaint);

    // Circle border
    final borderPaint = Paint()
      ..color = AppColors.accentOrange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    canvas.drawCircle(center, radius, borderPaint);

    // Animated dashed circle if drawing
    if (isDrawing) {
      final dashedPaint = Paint()
        ..color = Colors.white.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      _drawDashedCircle(canvas, center, radius + 5, dashedPaint);
    }

    // Center point
    final centerPaint = Paint()
      ..color = AppColors.accentOrange
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, 6, centerPaint);

    // White inner border for center point
    final centerBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(center, 6, centerBorderPaint);

    // Selection handles (for resizing - optional)
    if (!isDrawing && radius > 30) {
      final handlePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;

      final handleBorderPaint = Paint()
        ..color = AppColors.accentOrange
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      // Draw handles at cardinal points
      final handlePositions = [
        Offset(center.dx, center.dy - radius), // Top
        Offset(center.dx + radius, center.dy), // Right
        Offset(center.dx, center.dy + radius), // Bottom
        Offset(center.dx - radius, center.dy), // Left
      ];

      for (final pos in handlePositions) {
        canvas.drawCircle(pos, 8, handlePaint);
        canvas.drawCircle(pos, 8, handleBorderPaint);
      }
    }
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
  ) {
    const dashLength = 10.0;
    const dashSpace = 5.0;
    const totalDashes = 360 / (dashLength + dashSpace);

    for (int i = 0; i < totalDashes; i++) {
      final startAngle = (i * (dashLength + dashSpace)) * (3.14159 / 180);
      final sweepAngle = dashLength * (3.14159 / 180);

      final path = Path()
        ..addArc(
          Rect.fromCircle(center: center, radius: radius),
          startAngle,
          sweepAngle,
        );

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(CircleSelectionPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.isDrawing != isDrawing;
  }
}
