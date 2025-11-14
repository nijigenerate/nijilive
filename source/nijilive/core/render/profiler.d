module nijilive.core.render.profiler;

import core.time : Duration, MonoTime, seconds;
import std.array : array;
import std.algorithm : sort;
import std.format : format;
import std.stdio : writeln;

private class RenderProfiler {
    long[string] accumUsec;
    size_t[string] callCounts;
    MonoTime lastReport;
    size_t frameCount;

    void addSample(string label, Duration sample) {
        accumUsec[label] += sample.total!"usecs";
        callCounts[label] += 1;
    }

    void frameCompleted() {
        frameCount++;
        auto now = MonoTime.currTime;
        if (lastReport == MonoTime.init) {
            lastReport = now;
            return;
        }
        auto elapsed = now - lastReport;
        if (elapsed >= 1.seconds) {
            report(elapsed);
            accumUsec = typeof(accumUsec).init;
            callCounts = typeof(callCounts).init;
            frameCount = 0;
            lastReport = now;
        }
    }

private:
    void report(Duration interval) {
        double secs = interval.total!"usecs" / 1_000_000.0;
        writeln(format!"[RenderProfiler] %.3fs window (%s frames)"(secs, frameCount));
        auto entries = accumUsec.byKeyValue.array;
        sort!((a, b) => a.value > b.value)(entries);
        foreach (entry; entries) {
            double totalMs = entry.value / 1000.0;
            auto count = entry.key in callCounts ? callCounts[entry.key] : 0;
            double avgMs = count ? totalMs / cast(double)count : totalMs;
            writeln(format!"  %-18s total=%8.3f ms  avg=%6.3f ms  calls=%6s"(entry.key, totalMs, avgMs, count));
        }
        if (entries.length == 0) {
            writeln("  (no instrumented passes recorded)");
        }
    }
}

private RenderProfiler profiler() {
    static RenderProfiler instance;
    if (instance is null)
        instance = new RenderProfiler();
    return instance;
}

struct RenderProfileScope {
    private string label;
    private MonoTime start;
    private bool active;

    this(string label) {
        this.label = label;
        start = MonoTime.currTime;
        active = true;
    }

    void stop() {
        if (!active || label.length == 0) return;
        auto duration = MonoTime.currTime - start;
        profiler().addSample(label, duration);
        active = false;
    }

    ~this() {
        stop();
    }
}

RenderProfileScope profileScope(string label) {
    return RenderProfileScope(label);
}

void renderProfilerFrameCompleted() {
    profiler().frameCompleted();
}
