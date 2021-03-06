// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:ui' show Point, Offset;

import 'package:meta/meta.dart';

import 'arena.dart';
import 'binding.dart';
import 'constants.dart';
import 'drag.dart';
import 'events.dart';
import 'recognizer.dart';
import 'velocity_tracker.dart';

/// Signature for when [MultiDragGestureRecognizer] recognizes the start of a drag gesture.
typedef Drag GestureMultiDragStartCallback(Point position);

/// Interface for receiving updates about drags from a [MultiDragGestureRecognizer].
abstract class Drag {
  /// The pointer has moved.
  void update(DragUpdateDetails details) { }

  /// The pointer is no longer in contact with the screen.
  ///
  /// The velocity at which the pointer was moving when it stopped contacting
  /// the screen is available in the `details`.
  void end(DragEndDetails details) { }

  /// The input from the pointer is no longer directed towards this receiver.
  ///
  /// For example, the user might have been interrupted by a system-modal dialog
  /// in the middle of the drag.
  void cancel() { }
}

/// Per-pointer state for a [MultiDragGestureRecognizer].
///
/// A [MultiDragGestureRecognizer] tracks each pointer separately. The state for
/// each pointer is a subclass of [MultiDragPointerState].
abstract class MultiDragPointerState {
  /// Creates per-pointer state for a [MultiDragGestureRecognizer].
  ///
  /// The [initialPosition] argument must not be null.
  MultiDragPointerState(this.initialPosition) {
    assert(initialPosition != null);
  }

  /// The global coordinates of the pointer when the pointer contacted the screen.
  final Point initialPosition;

  final VelocityTracker _velocityTracker = new VelocityTracker();
  Drag _client;

  /// The offset of the pointer from the last position that was reported to the client.
  ///
  /// After the pointer contacts the screen, the pointer might move some
  /// distance before this movement will be recognized as a drag. This field
  /// accumulates that movement so that we can report it to the client after
  /// the drag starts.
  Offset get pendingDelta => _pendingDelta;
  Offset _pendingDelta = Offset.zero;

  GestureArenaEntry _arenaEntry;
  void _setArenaEntry(GestureArenaEntry entry) {
    assert(_arenaEntry == null);
    assert(pendingDelta != null);
    assert(_client == null);
    _arenaEntry = entry;
  }

  /// Resolve this pointer's entry in the [GestureArenaManager] with the given disposition.
  void resolve(GestureDisposition disposition) {
    _arenaEntry.resolve(disposition);
  }

  void _move(PointerMoveEvent event) {
    assert(_arenaEntry != null);
    _velocityTracker.addPosition(event.timeStamp, event.position);
    if (_client != null) {
      assert(pendingDelta == null);
      _client.update(new DragUpdateDetails(delta: event.delta));
    } else {
      assert(pendingDelta != null);
      _pendingDelta += event.delta;
      checkForResolutionAfterMove();
    }
    return null;
  }

  /// Override this to call resolve() if the drag should be accepted or rejected.
  /// This is called when a pointer movement is received, but only if the gesture
  /// has not yet been resolved.
  void checkForResolutionAfterMove() { }

  /// Called when the gesture was accepted.
  ///
  /// Either immediately or at some future point before the gesture is disposed,
  /// call starter(), passing it initialPosition, to start the drag.
  void accepted(GestureMultiDragStartCallback starter);

  /// Called when the gesture was rejected.
  ///
  /// [dispose()] will be called immediately following this.
  void rejected() {
    assert(_arenaEntry != null);
    assert(_client == null);
    assert(pendingDelta != null);
    _pendingDelta = null;
    _arenaEntry = null;
  }

  void _startDrag(Drag client) {
    assert(_arenaEntry != null);
    assert(_client == null);
    assert(client != null);
    assert(pendingDelta != null);
    _client = client;
    _client.update(new DragUpdateDetails(delta: pendingDelta));
    _pendingDelta = null;
  }

  void _up() {
    assert(_arenaEntry != null);
    if (_client != null) {
      assert(pendingDelta == null);
      _client.end(new DragEndDetails(velocity: _velocityTracker.getVelocity() ?? Velocity.zero));
      _client = null;
    } else {
      assert(pendingDelta != null);
      _pendingDelta = null;
    }
    _arenaEntry = null;
  }

  void _cancel() {
    assert(_arenaEntry != null);
    if (_client != null) {
      assert(pendingDelta == null);
      _client.cancel();
      _client = null;
    } else {
      assert(pendingDelta != null);
      _pendingDelta = null;
    }
    _arenaEntry = null;
  }

  /// Releases any resources used by the object.
  @mustCallSuper
  void dispose() {
    _arenaEntry?.resolve(GestureDisposition.rejected);
    assert(() { _pendingDelta = null; return true; });
  }
}

/// Recognizes movement on a per-pointer basis.
///
/// In contrast to [DragGestureRecognizer], [MultiDragGestureRecognizer] watches
/// each pointer separately, which means multiple drags can be recognized
/// concurrently if multiple pointers are in contact with the screen.
///
/// [MultiDragGestureRecognizer] is not intended to be used directly. Instead,
/// consider using one of its subclasses to recognize specific types for drag
/// gestures.
///
/// See also:
///
///  * [HorizontalMultiDragGestureRecognizer]
///  * [VerticalMultiDragGestureRecognizer]
///  * [ImmediateMultiDragGestureRecognizer]
///  * [DelayedMultiDragGestureRecognizer]
abstract class MultiDragGestureRecognizer<T extends MultiDragPointerState> extends GestureRecognizer {
  /// Called when this class recognizes the start of a drag gesture.
  ///
  /// The remaining notifications for this drag gesture are delivered to the
  /// [Drag] object returned by this callback.
  GestureMultiDragStartCallback onStart;

  Map<int, T> _pointers = <int, T>{};

  @override
  void addPointer(PointerDownEvent event) {
    assert(_pointers != null);
    assert(event.pointer != null);
    assert(event.position != null);
    assert(!_pointers.containsKey(event.pointer));
    T state = createNewPointerState(event);
    _pointers[event.pointer] = state;
    GestureBinding.instance.pointerRouter.addRoute(event.pointer, _handleEvent);
    state._setArenaEntry(GestureBinding.instance.gestureArena.add(event.pointer, this));
  }

  /// Subclasses should override this function to create per-pointer state
  /// objects to track the pointer associated with the given event.
  T createNewPointerState(PointerDownEvent event);

  void _handleEvent(PointerEvent event) {
    assert(_pointers != null);
    assert(event.pointer != null);
    assert(event.timeStamp != null);
    assert(event.position != null);
    assert(_pointers.containsKey(event.pointer));
    T state = _pointers[event.pointer];
    if (event is PointerMoveEvent) {
      state._move(event);
    } else if (event is PointerUpEvent) {
      assert(event.delta == Offset.zero);
      state._up();
      _removeState(event.pointer);
    } else if (event is PointerCancelEvent) {
      assert(event.delta == Offset.zero);
      state._cancel();
      _removeState(event.pointer);
    } else if (event is! PointerDownEvent) {
      // we get the PointerDownEvent that resulted in our addPointer gettig called since we
      // add ourselves to the pointer router then (before the pointer router has heard of
      // the event).
      assert(false);
    }
  }

  @override
  void acceptGesture(int pointer) {
    assert(_pointers != null);
    T state = _pointers[pointer];
    if (state == null)
      return; // We might already have canceled this drag if the up comes before the accept.
    state.accepted((Point initialPosition) => _startDrag(initialPosition, pointer));
  }

  Drag _startDrag(Point initialPosition, int pointer) {
    assert(_pointers != null);
    T state = _pointers[pointer];
    assert(state != null);
    assert(state._pendingDelta != null);
    Drag drag;
    if (onStart != null)
      drag = onStart(initialPosition);
    if (drag != null) {
      state._startDrag(drag);
    } else {
      _removeState(pointer);
    }
    return drag;
  }

  @override
  void rejectGesture(int pointer) {
    assert(_pointers != null);
    if (_pointers.containsKey(pointer)) {
      T state = _pointers[pointer];
      assert(state != null);
      state.rejected();
      _removeState(pointer);
    } // else we already preemptively forgot about it (e.g. we got an up event)
  }

  void _removeState(int pointer) {
    assert(_pointers != null);
    assert(_pointers.containsKey(pointer));
    GestureBinding.instance.pointerRouter.removeRoute(pointer, _handleEvent);
    _pointers.remove(pointer).dispose();
  }

  @override
  void dispose() {
    for (int pointer in _pointers.keys.toList())
      _removeState(pointer);
    assert(_pointers.isEmpty);
    _pointers = null;
    super.dispose();
  }
}

class _ImmediatePointerState extends MultiDragPointerState {
  _ImmediatePointerState(Point initialPosition) : super(initialPosition);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta.distance > kTouchSlop)
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

/// Recognizes movement both horizontally and vertically on a per-pointer basis.
///
/// In contrast to [PanGestureRecognizer], [ImmediateMultiDragGestureRecognizer]
/// watches each pointer separately, which means multiple drags can be
/// recognized concurrently if multiple pointers are in contact with the screen.
///
/// See also:
///
///  * [PanGestureRecognizer]
///  * [DelayedMultiDragGestureRecognizer]
class ImmediateMultiDragGestureRecognizer extends MultiDragGestureRecognizer<_ImmediatePointerState> {
  @override
  _ImmediatePointerState createNewPointerState(PointerDownEvent event) {
    return new _ImmediatePointerState(event.position);
  }

  @override
  String toStringShort() => 'multidrag';
}


class _HorizontalPointerState extends MultiDragPointerState {
  _HorizontalPointerState(Point initialPosition) : super(initialPosition);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta.dx.abs() > kTouchSlop)
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

/// Recognizes movement in the horizontal direction on a per-pointer basis.
///
/// In contrast to [HorizontalDragGestureRecognizer],
/// [HorizontalMultiDragGestureRecognizer] watches each pointer separately,
/// which means multiple drags can be recognized concurrently if multiple
/// pointers are in contact with the screen.
///
/// See also:
///
///  * [HorizontalDragGestureRecognizer]
class HorizontalMultiDragGestureRecognizer extends MultiDragGestureRecognizer<_HorizontalPointerState> {
  @override
  _HorizontalPointerState createNewPointerState(PointerDownEvent event) {
    return new _HorizontalPointerState(event.position);
  }

  @override
  String toStringShort() => 'horizontal multidrag';
}


class _VerticalPointerState extends MultiDragPointerState {
  _VerticalPointerState(Point initialPosition) : super(initialPosition);

  @override
  void checkForResolutionAfterMove() {
    assert(pendingDelta != null);
    if (pendingDelta.dy.abs() > kTouchSlop)
      resolve(GestureDisposition.accepted);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}

/// Recognizes movement in the vertical direction on a per-pointer basis.
///
/// In contrast to [VerticalDragGestureRecognizer],
/// [VerticalMultiDragGestureRecognizer] watches each pointer separately,
/// which means multiple drags can be recognized concurrently if multiple
/// pointers are in contact with the screen.
///
/// See also:
///
///  * [VerticalDragGestureRecognizer]
class VerticalMultiDragGestureRecognizer extends MultiDragGestureRecognizer<_VerticalPointerState> {
  @override
  _VerticalPointerState createNewPointerState(PointerDownEvent event) {
    return new _VerticalPointerState(event.position);
  }

  @override
  String toStringShort() => 'vertical multidrag';
}

class _DelayedPointerState extends MultiDragPointerState {
  _DelayedPointerState(Point initialPosition, Duration delay) : super(initialPosition) {
    assert(delay != null);
    _timer = new Timer(delay, _delayPassed);
  }

  Timer _timer;
  GestureMultiDragStartCallback _starter;

  void _delayPassed() {
    assert(_timer != null);
    assert(pendingDelta != null);
    assert(pendingDelta.distance <= kTouchSlop);
    _timer = null;
    if (_starter != null) {
      _starter(initialPosition);
      _starter = null;
    } else {
      resolve(GestureDisposition.accepted);
    }
    assert(_starter == null);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    assert(_starter == null);
    if (_timer == null)
      starter(initialPosition);
    else
      _starter = starter;
  }

  @override
  void checkForResolutionAfterMove() {
    assert(_timer != null);
    assert(pendingDelta != null);
    if (pendingDelta.distance > kTouchSlop)
      resolve(GestureDisposition.rejected);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Recognizes movement both horizontally and vertically on a per-pointer basis after a delay.
///
/// In constrast to [ImmediateMultiDragGestureRecognizer],
/// [DelayedMultiDragGestureRecognizer] waits for a [delay] before recognizing
/// the drag. If the pointer moves more than [kTouchSlop] before the delay
/// expires, the gesture is not recognized.
///
/// In contrast to [PanGestureRecognizer], [DelayedMultiDragGestureRecognizer]
/// watches each pointer separately, which means multiple drags can be
/// recognized concurrently if multiple pointers are in contact with the screen.
///
/// See also:
///
///  * [PanGestureRecognizer]
///  * [ImmediateMultiDragGestureRecognizer]
class DelayedMultiDragGestureRecognizer extends MultiDragGestureRecognizer<_DelayedPointerState> {
  /// Creates a drag recognizer that works on a per-pointer basis after a delay.
  ///
  /// In order for a drag to be recognized by this recognizer, the pointer must
  /// remain in the same place for [delay] (up to [kTouchSlop]). The [delay]
  /// defaults to [kLongPressTimeout] to match [LongPressGestureRecognizer] but
  /// can be changed for specific behaviors.
  DelayedMultiDragGestureRecognizer({
    Duration delay: kLongPressTimeout
  }) : _delay = delay {
    assert(delay != null);
  }

  /// The amount of time the pointer must remain in the same place for the drag
  /// to be recognized.
  Duration get delay => _delay;
  Duration _delay;
  set delay(Duration value) {
    assert(value != null);
    _delay = value;
  }

  @override
  _DelayedPointerState createNewPointerState(PointerDownEvent event) {
    return new _DelayedPointerState(event.position, _delay);
  }

  @override
  String toStringShort() => 'long multidrag';
}
