import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';
import '../../settings/onboarding_experiment.dart';

/// Represents a step in the interactive spotlight coachmark tutorial.
class SpotlightStep {
  final GlobalKey targetKey;
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onStepEntered;

  const SpotlightStep({
    required this.targetKey,
    required this.title,
    required this.description,
    required this.icon,
    this.onStepEntered,
  });
}

/// Interactive Spotlight Coachmark Overlay for Aurora Downloader.
/// Darkens the screen and punches a glowing cutout over targeted widgets.
class OnboardingSpotlightOverlay extends StatefulWidget {
  final List<SpotlightStep> steps;
  final VoidCallback? onDismissed;

  const OnboardingSpotlightOverlay({
    super.key,
    required this.steps,
    this.onDismissed,
  });

  /// Present the spotlight overlay over the current context's Overlay.
  static OverlayEntry? show(
    BuildContext context, {
    required List<SpotlightStep> steps,
    VoidCallback? onDismissed,
  }) {
    final overlayState = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (ctx) => OnboardingSpotlightOverlay(
        steps: steps,
        onDismissed: () {
          entry.remove();
          onDismissed?.call();
        },
      ),
    );

    overlayState.insert(entry);
    return entry;
  }

  @override
  State<OnboardingSpotlightOverlay> createState() =>
      _OnboardingSpotlightOverlayState();
}

class _OnboardingSpotlightOverlayState
    extends State<OnboardingSpotlightOverlay> {
  int _currentStepIndex = 0;
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    // Defer tab switches / parent setState until after this Overlay Builder
    // finishes building — calling onStepEntered synchronously here causes
    // "setState() called during build" on AuroraHome.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _enterCurrentStep();
    });
  }

  /// Runs [SpotlightStep.onStepEntered] then schedules layout retries.
  /// Always post-frame so parent [setState] (e.g. tab switch) is legal.
  void _enterCurrentStep() {
    if (!mounted || widget.steps.isEmpty) return;
    final index = _currentStepIndex.clamp(0, widget.steps.length - 1);
    widget.steps[index].onStepEntered?.call();
    _scheduleRetry();
  }

  static const int _maxLayoutRetries = 8;

  void _scheduleRetry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _retryCount < _maxLayoutRetries) {
        _retryCount++;
        setState(() {});
      }
    });
  }

  Future<void> _finishOnboarding() async {
    await OnboardingExperiment.markCompleted();
    if (mounted) {
      widget.onDismissed?.call();
    }
  }

  void _nextStep() {
    if (_currentStepIndex < widget.steps.length - 1) {
      setState(() {
        _currentStepIndex++;
        _retryCount = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _enterCurrentStep();
      });
    } else {
      _finishOnboarding();
    }
  }

  Rect? _getTargetRect(GlobalKey key) {
    final context = key.currentContext;
    if (context == null) return null;
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) return null;

    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return null;

    return offset & size;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;

    if (widget.steps.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentStep = widget.steps[_currentStepIndex];
    final targetRect = _getTargetRect(currentStep.targetKey);
    if (targetRect == null && _retryCount < _maxLayoutRetries) {
      _scheduleRetry();
    }

    // Padding around target cutout
    final cutoutRect = targetRect != null
        ? Rect.fromLTRB(
            (targetRect.left - 6).clamp(0.0, screenSize.width),
            (targetRect.top - 6).clamp(0.0, screenSize.height),
            (targetRect.right + 6).clamp(0.0, screenSize.width),
            (targetRect.bottom + 6).clamp(0.0, screenSize.height),
          )
        : null;

    final isTargetNearTop =
        cutoutRect != null ? cutoutRect.center.dy < screenSize.height * 0.5 : true;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Background Painter with cutout
          CustomPaint(
            size: screenSize,
            painter: _SpotlightPainter(
              cutoutRect: cutoutRect,
              accentColor: ac.accentFrost,
            ),
          ),

          // Dismiss / Tap Backdrop Listener
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _nextStep,
              child: const SizedBox.expand(),
            ),
          ),

          // Tooltip Card Container
          Positioned(
            left: 20,
            right: 20,
            top: (isTargetNearTop && cutoutRect != null)
                ? cutoutRect.bottom + 16
                : null,
            bottom: cutoutRect == null
                ? screenSize.height * 0.35
                : (!isTargetNearTop ? (screenSize.height - cutoutRect.top) + 16 : null),
            child: TweenAnimationBuilder<double>(
              key: ValueKey(_currentStepIndex),
              duration: const Duration(milliseconds: 300),
              tween: Tween(begin: 0.0, end: 1.0),
              builder: (context, animValue, child) {
                return Opacity(
                  opacity: animValue,
                  child: Transform.translate(
                    offset: Offset(0, (1 - animValue) * 12),
                    child: child,
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: ac.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: ac.accentFrost.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Step Badge & Icon Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: ac.accentFrost.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            currentStep.icon,
                            color: ac.accentFrost,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'STEP ${_currentStepIndex + 1} OF ${widget.steps.length}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                  color: ac.accentFrost,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                currentStep.title,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: ac.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Description text
                    Text(
                      currentStep.description,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: ac.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Bottom Navigation Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Skip Button
                        TextButton(
                          onPressed: _finishOnboarding,
                          style: TextButton.styleFrom(
                            foregroundColor: ac.textSecondary,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          child: const Text('Skip tutorial'),
                        ),

                        // Indicators & Next Button
                        Row(
                          children: [
                            // Dots
                            Row(
                              children: List.generate(
                                widget.steps.length,
                                (idx) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  margin: const EdgeInsets.only(right: 5),
                                  width: _currentStepIndex == idx ? 16 : 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: _currentStepIndex == idx
                                        ? ac.accentFrost
                                        : ac.textSecondary
                                            .withValues(alpha: 0.3),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),

                            ElevatedButton(
                              onPressed: _nextStep,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ac.accentFrost,
                                foregroundColor: Colors.black,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                _currentStepIndex == widget.steps.length - 1
                                    ? 'Got it!'
                                    : 'Next',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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
}

class _SpotlightPainter extends CustomPainter {
  final Rect? cutoutRect;
  final Color accentColor;

  _SpotlightPainter({
    required this.cutoutRect,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullScreenPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.78)
      ..style = PaintingStyle.fill;

    if (cutoutRect == null) {
      canvas.drawPath(fullScreenPath, paint);
      return;
    }

    final rrect = RRect.fromRectAndRadius(
      cutoutRect!,
      const Radius.circular(16),
    );

    final cutoutPath = Path()..addRRect(rrect);
    final backgroundPath = Path.combine(
      PathOperation.difference,
      fullScreenPath,
      cutoutPath,
    );

    canvas.drawPath(backgroundPath, paint);

    // Glowing border around cutout
    final borderPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) {
    return oldDelegate.cutoutRect != cutoutRect ||
        oldDelegate.accentColor != accentColor;
  }
}
