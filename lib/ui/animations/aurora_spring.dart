import 'package:flutter/physics.dart';

/// Spring physics presets used across Aurora's UI (anatomy 8.4 / animation table).
class AuroraSpring {
  const AuroraSpring._();

  /// Tab-switch scale spring: mass=1, stiffness=300, damping=15.
  static SpringSimulation tabSwitch({
    double start = 0,
    double end = 1,
    double velocity = 0,
  }) =>
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 15),
        start,
        end,
        velocity,
      );

  /// Card swipe snap-back spring: mass=1, stiffness=200, damping=20.
  static SpringSimulation cardSnap({
    double start = 0,
    double end = 0,
    double velocity = 0,
  }) =>
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 200, damping: 20),
        start,
        end,
        velocity,
      );
}
