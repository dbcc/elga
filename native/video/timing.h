#pragma once
#include <algorithm>
#include <cstdint>

namespace elga {
constexpr int64_t second = 10000000;
struct Cadence {
    int64_t nominal = second / 60, last = 0, patternStart = 0;
    uint32_t run = 1, candidate = 1, factor = 1, observations = 0;
    bool seeded = false;
    void reset(int64_t period) { *this = {}; nominal = std::max<int64_t>(period, 1); }
    // Compare exact GPU pixels. A long static scene never establishes a slower
    // rate; only repeated, bounded runs separated by actual motion do.
    bool observe(int64_t timestamp, bool equal) {
        if (!seeded) { seeded = true; last = timestamp; return false; }
        if (timestamp <= last || timestamp - last > nominal * 3 / 2) {
            reset(nominal); seeded = true; last = timestamp; return true;
        }
        last = timestamp;
        if (equal) { run = std::min(run + 1, 1024u); return false; }
        bool changed = false;
        if (run > 4) { candidate = 1; observations = 0; patternStart = 0; run = 1; return false; }
        if (factor != 1 && run != factor) { factor = 1; changed = true; }
        if (candidate != run || !observations) {
            candidate = run; patternStart = timestamp; observations = 1;
        } else { ++observations; }
        if (timestamp - patternStart >= second && observations >= 8 && factor != candidate) {
            factor = candidate; changed = true;
        }
        run = 1;
        return changed;
    }
    int64_t period() const { return nominal * factor; }
};
inline bool displayCanDouble(double refresh, int64_t period) {
    return refresh > 0 && period > 0 && refresh + 0.5 >= 2.0 * second / period;
}
// Manual source-rate override. Sample by capture timestamps, not callback count,
// so missing callbacks cannot shift the phase. Keep 59.94 -> 29.97 synchronized
// to the input instead of periodically selecting a repeated HDMI frame.
struct FixedCadence {
    int64_t period = second / 30, tolerance = 0, origin = 0, lastSlot = -1;
    bool seeded = false;
    void reset(int64_t nominal) {
        *this = {};
        nominal = std::max<int64_t>(nominal, 1);
        period = std::max<int64_t>(second / 30, nominal);
        int64_t multiple = std::max<int64_t>(1, (period + nominal / 2) / nominal);
        int64_t aligned = multiple * nominal;
        if (aligned >= period - period / 100 && aligned <= period + period / 100) period = aligned;
        tolerance = nominal / 4;
    }
    bool accept(int64_t timestamp) {
        if (!seeded) { seeded = true; origin = timestamp; lastSlot = 0; return true; }
        if (timestamp <= origin) return false;
        int64_t slot = (timestamp - origin + tolerance) / period;
        if (slot <= lastSlot) return false;
        lastSlot = slot;
        return true;
    }
    // A replacement from the second HDMI repeat still represents the same game
    // frame. Schedule it on that slot, not one capture period late.
    int64_t timestamp() const { return origin + lastSlot * period; }
};
struct Timeline {
    int64_t origin = 0, source = 0, last = 0;
    bool seeded = false;
    void reset() { *this = {}; }
    bool discontinuity(int64_t timestamp, int64_t nominal, int64_t fixedPeriod = 0) const {
        // In manual mode a lost HDMI repeat is not a new source clock. Preserve
        // the delay and sampling phase across short gaps; a restart/long stall
        // still invalidates all queued video and audio.
        int64_t maximumGap = fixedPeriod ? fixedPeriod * 3 : nominal * 3 / 2;
        return seeded && (timestamp <= last || timestamp - last > maximumGap);
    }
    void observe(int64_t timestamp, int64_t arrival) {
        if (!seeded) { origin = arrival; source = timestamp; seeded = true; }
        last = timestamp;
    }
    int64_t due(int64_t timestamp, int64_t delay) const { return origin + timestamp - source + delay; }
};
}
