// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show JSON, JsonEncoder;
import 'dart:math' as math;

import 'package:file/file.dart';
import 'package:path/path.dart' as path;

import 'common.dart';
import 'timeline.dart';

const JsonEncoder _prettyEncoder = const JsonEncoder.withIndent('  ');

/// The maximum amount of time considered safe to spend for a frame's build
/// phase. Anything past that is in the danger of missing the frame as 60FPS.
const Duration kBuildBudget = const Duration(milliseconds: 8);

/// Extracts statistics from a [Timeline].
class TimelineSummary {
  /// Creates a timeline summary given a full timeline object.
  TimelineSummary.summarize(this._timeline);

  final Timeline _timeline;

  /// Average amount of time spent per frame in the framework building widgets,
  /// updating layout, painting and compositing.
  ///
  /// Returns null if no frames were recorded.
  double computeAverageFrameBuildTimeMillis() {
    return _averageInMillis(_extractFrameDurations());
  }

  /// The longest frame build time in milliseconds.
  ///
  /// Returns null if no frames were recorded.
  double computeWorstFrameBuildTimeMillis() {
    return _maxInMillis(_extractFrameDurations());
  }

  /// The number of frames that missed the [kBuildBudget] and therefore are
  /// in the danger of missing frames.
  int computeMissedFrameBuildBudgetCount([Duration frameBuildBudget = kBuildBudget]) => _extractFrameDurations()
    .where((Duration duration) => duration > kBuildBudget)
    .length;

  /// Average amount of time spent per frame in the GPU rasterizer.
  ///
  /// Returns null if no frames were recorded.
  double computeAverageFrameRasterizerTimeMillis() {
    return _averageInMillis(_extractDuration(_extractGpuRasterizerDrawEvents()));
  }

  /// The longest frame rasterization time in milliseconds.
  ///
  /// Returns null if no frames were recorded.
  double computeWorstFrameRasterizerTimeMillis() {
    return _maxInMillis(_extractDuration(_extractGpuRasterizerDrawEvents()));
  }

  /// The number of frames that missed the [kBuildBudget] on the GPU and
  /// therefore are in the danger of missing frames.
  int computeMissedFrameRasterizerBudgetCount([Duration frameBuildBudget = kBuildBudget]) => _extractGpuRasterizerDrawEvents()
      .where((TimedEvent event) => event.duration > kBuildBudget)
      .length;

  /// The total number of frames recorded in the timeline.
  int countFrames() => _extractFrameDurations().length;

  /// Encodes this summary as JSON.
  Map<String, dynamic> get summaryJson {
    return <String, dynamic> {
      'average_frame_build_time_millis': computeAverageFrameBuildTimeMillis(),
      'worst_frame_build_time_millis': computeWorstFrameBuildTimeMillis(),
      'missed_frame_build_budget_count': computeMissedFrameBuildBudgetCount(),
      'average_frame_rasterizer_time_millis': computeAverageFrameRasterizerTimeMillis(),
      'worst_frame_rasterizer_time_millis': computeWorstFrameRasterizerTimeMillis(),
      'missed_frame_rasterizer_budget_count': computeMissedFrameRasterizerBudgetCount(),
      'frame_count': countFrames(),
      'frame_build_times': _extractFrameDurations()
        .map((Duration duration) => duration.inMicroseconds)
        .toList(),
      'frame_rasterizer_times': _extractGpuRasterizerDrawEvents()
          .map((TimedEvent event) => event.duration.inMicroseconds)
          .toList(),
    };
  }

  /// Writes all of the recorded timeline data to a file.
  Future<Null> writeTimelineToFile(
    String traceName, {
    String destinationDirectory,
    bool pretty: false,
  }) async {
    destinationDirectory ??= testOutputsDirectory;
    await fs.directory(destinationDirectory).create(recursive: true);
    final File file = fs.file(path.join(destinationDirectory, '$traceName.timeline.json'));
    await file.writeAsString(_encodeJson(_timeline.json, pretty));
  }

  /// Writes [summaryJson] to a file.
  Future<Null> writeSummaryToFile(
    String traceName, {
    String destinationDirectory,
    bool pretty: false,
  }) async {
    destinationDirectory ??= testOutputsDirectory;
    await fs.directory(destinationDirectory).create(recursive: true);
    final File file = fs.file(path.join(destinationDirectory, '$traceName.timeline_summary.json'));
    await file.writeAsString(_encodeJson(summaryJson, pretty));
  }

  String _encodeJson(Map<String, dynamic> json, bool pretty) {
    return pretty
      ? _prettyEncoder.convert(json)
      : JSON.encode(json);
  }

  List<TimelineEvent> _extractNamedEvents(String name) {
    return _timeline.events
      .where((TimelineEvent event) => event.name == name)
      .toList();
  }

  List<Duration> _extractDurations(String name) {
    return _extractNamedEvents(name).map((TimelineEvent event) => event.duration).toList();
  }

  /// Extracts timed events that are reported as a pair of begin/end events.
  ///
  /// See: https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU
  List<TimedEvent> _extractBeginEndEvents(String name) {
    final List<TimedEvent> result = <TimedEvent>[];

    // Timeline does not guarantee that the first event is the "begin" event.
    final Iterator<TimelineEvent> events = _extractNamedEvents(name)
        .skipWhile((TimelineEvent evt) => evt.phase != 'B').iterator;
    while (events.moveNext()) {
      final TimelineEvent beginEvent = events.current;
      if (events.moveNext()) {
        final TimelineEvent endEvent = events.current;
        result.add(new TimedEvent(
            beginEvent.timestampMicros,
            endEvent.timestampMicros
        ));
      }
    }

    return result;
  }

  double _averageInMillis(Iterable<Duration> durations) {
    if (durations.isEmpty)
      return null;

    final int total = durations.fold<int>(0, (int t, Duration duration) => t + duration.inMilliseconds);
    return total / durations.length;
  }

  double _maxInMillis(Iterable<Duration> durations) {
    if (durations.isEmpty)
      return null;

    return durations
        .map<double>((Duration duration) => duration.inMilliseconds.toDouble())
        .reduce(math.max);
  }

  List<TimedEvent> _extractGpuRasterizerDrawEvents() => _extractBeginEndEvents('GPURasterizer::Draw');

  List<Duration> _extractFrameDurations() => _extractDurations('Frame');

  Iterable<Duration> _extractDuration(Iterable<TimedEvent> events) {
    return events.map((TimedEvent e) => e.duration);
  }
}

/// Timing information about an event that happened in the event loop.
class TimedEvent {
  /// Creates a timed event given begin and end timestamps in microseconds.
  TimedEvent(this.beginTimeMicros, this.endTimeMicros)
    : this.duration = new Duration(microseconds: endTimeMicros - beginTimeMicros);

  /// The timestamp when the event began.
  final int beginTimeMicros;

  /// The timestamp when the event ended.
  final int endTimeMicros;

  /// The duration of the event.
  final Duration duration;
}
