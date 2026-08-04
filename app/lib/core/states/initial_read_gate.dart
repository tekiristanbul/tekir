import 'dart:async';

import 'package:flutter/widgets.dart';

/// How long an initial read may run before any loading ui appears.
/// Most reads finish inside this window; a flashing skeleton is noise
/// (docs/design/app-states.md, timing contract).
const kInitialReadDelay = Duration(milliseconds: 400);

/// When the single status line ("yakındaki kediler getiriliyor") joins
/// the skeleton.
const kInitialReadStatusDelay = Duration(milliseconds: 1600);

/// When the wait ends and the owning feature switches to its error
/// state. Bounded reads only — never applied to uploads or writes.
const kInitialReadTimeout = Duration(seconds: 6);

/// The phase of an in-flight initial read, per the timing contract.
enum InitialReadPhase {
  /// 0–400 ms (or no read in flight): show nothing loading-related.
  hidden,

  /// 400 ms+: the screen's future layout stands in as a skeleton.
  skeleton,

  /// 1.6 s+: the skeleton plus one status line.
  skeletonWithStatus,

  /// 6 s+: the wait is over — the feature renders its error state.
  timedOut,
}

/// Drives the shared timing contract for **initial reads only**
/// (docs/design/app-states.md). Features render their own skeleton
/// geometry; this gate owns *when* each phase may appear. User-triggered
/// mutations never go through this gate — their feedback starts in the
/// same frame as the tap.
///
/// The clock restarts from [InitialReadPhase.hidden] every time
/// [reading] flips back to true, so a retry gets a fresh 400 ms of
/// silence.
class InitialReadGate extends StatefulWidget {
  const InitialReadGate({
    super.key,
    required this.reading,
    required this.builder,
  });

  /// Whether the initial read is in flight.
  final bool reading;

  /// Builds the subtree for the current [InitialReadPhase]. Called with
  /// [InitialReadPhase.hidden] whenever [reading] is false.
  final Widget Function(BuildContext context, InitialReadPhase phase) builder;

  @override
  State<InitialReadGate> createState() => _InitialReadGateState();
}

class _InitialReadGateState extends State<InitialReadGate> {
  InitialReadPhase _phase = InitialReadPhase.hidden;
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    if (widget.reading) _start();
  }

  @override
  void didUpdateWidget(InitialReadGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reading == oldWidget.reading) return;
    _stop();
    if (widget.reading) _start();
  }

  void _start() {
    _timers.addAll([
      Timer(kInitialReadDelay, () {
        setState(() => _phase = InitialReadPhase.skeleton);
      }),
      Timer(kInitialReadStatusDelay, () {
        setState(() => _phase = InitialReadPhase.skeletonWithStatus);
      }),
      Timer(kInitialReadTimeout, () {
        setState(() => _phase = InitialReadPhase.timedOut);
      }),
    ]);
  }

  void _stop() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _phase = InitialReadPhase.hidden;
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      widget.reading ? _phase : InitialReadPhase.hidden,
    );
  }
}
