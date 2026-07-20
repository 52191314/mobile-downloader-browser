/// Runtime feature flags for premium-gated surfaces.
///
/// Set `kDriveSyncEnabled = false` until GCP OAuth verification is restored
/// or the Drive code is removed. All Drive Settings tiles, auto-sync, and
/// marketing copy check this flag. Prefer the flag over scattering
/// `BuildChannel.isPlay` checks.
const bool kDriveSyncEnabled = false;
