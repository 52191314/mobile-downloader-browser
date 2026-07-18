import 'package:flutter/material.dart';

import '../../theme/aurora_palette.dart';

/// Floating chip with a 30-second countdown ring used while the element
/// picker is active.
class PickerCancelChip extends StatefulWidget {
  final VoidCallback onCancel;

  const PickerCancelChip({super.key, required this.onCancel});

  @override
  State<PickerCancelChip> createState() => _PickerCancelChipState();
}

class _PickerCancelChipState extends State<PickerCancelChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return SizedBox(
          width: 100,
          height: 56,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  value: 1.0 - _controller.value,
                  strokeWidth: 3.0,
                  color: context.ac.accentFrost,
                  backgroundColor: context.ac.surfaceElevated,
                ),
              ),
              Material(
                color: context.ac.overlaySurface,
                elevation: 8,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: widget.onCancel,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.close,
                          size: 18,
                          color: context.ac.textPrimary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Cancel',
                          style: TextStyle(color: context.ac.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
