/// Resource consumption metrics captured during sandbox execution.
class SandboxMetrics {
  /// Peak RAM memory consumed in bytes (if supported by sandbox backend).
  final int? peakMemoryBytes;

  /// CPU time spent executing.
  final Duration? cpuTime;

  const SandboxMetrics({
    this.peakMemoryBytes,
    this.cpuTime,
  });

  const SandboxMetrics.empty()
      : peakMemoryBytes = null,
        cpuTime = null;

  Map<String, dynamic> toJson() => {
        if (peakMemoryBytes != null) 'peakMemoryBytes': peakMemoryBytes,
        if (cpuTime != null) 'cpuTimeMs': cpuTime!.inMilliseconds,
      };

  factory SandboxMetrics.fromJson(Map<String, dynamic> json) {
    return SandboxMetrics(
      peakMemoryBytes: json['peakMemoryBytes'] as int?,
      cpuTime: json['cpuTimeMs'] != null ? Duration(milliseconds: json['cpuTimeMs'] as int) : null,
    );
  }

  @override
  String toString() => 'SandboxMetrics(peakRAM: ${peakMemoryBytes ?? 'n/a'}, cpuTime: ${cpuTime?.inMilliseconds ?? 'n/a'}ms)';
}
