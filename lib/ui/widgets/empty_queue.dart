import 'package:flutter/material.dart';

import 'panel.dart';

class EmptyQueue extends StatelessWidget {
  const EmptyQueue({super.key});

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Icon(
                Icons.inbox_outlined,
                color: Theme.of(context).colorScheme.primary,
                size: 32,
              ),
              const SizedBox(height: 10),
              const Text('No downloads yet'),
            ],
          ),
        ),
      ),
    );
  }
}
