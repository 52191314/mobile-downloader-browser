import 'package:flutter/material.dart';

import '../../theme/aurora_colors.dart';
import 'panel.dart';

class EmptyQueue extends StatefulWidget {
  final String message;
  final IconData icon;

  const EmptyQueue({
    super.key,
    this.message = 'No downloads yet',
    this.icon = Icons.inbox_outlined,
  });

  @override
  State<EmptyQueue> createState() => _EmptyQueueState();
}

class _EmptyQueueState extends State<EmptyQueue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) => Transform.scale(
                  scale: _pulse.value,
                  child: child,
                ),
                child: Icon(
                  widget.icon,
                  color: AuroraColors.mutedDeep,
                  size: 48,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.message,
                style: TextStyle(
                  fontSize: 14,
                  color: AuroraColors.mutedText,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
