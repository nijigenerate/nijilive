module nijilive.core.diff_collect;

import nijilive.core.render.backends : RenderingBackend, BackendEnum;
import nijilive.core.runtime_state : tryRenderBackend;

alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);

struct DifferenceEvaluationRegion {
    int x;
    int y;
    int width;
    int height;
}

enum TileColumns = 16;
enum TileCount = TileColumns * TileColumns;

struct DifferenceEvaluationResult {
    double red;
    double green;
    double blue;
    double alpha;
    uint sampleCount;
    double[TileCount] tileTotals;
    double[TileCount] tileCounts;

    @property double total() const {
        return red + green + blue;
    }
}

private RenderBackend backendOrNull() {
    return tryRenderBackend();
}

void rpSetDifferenceEvaluationEnabled(bool enabled) {
    auto backend = backendOrNull();
    if (backend !is null) {
        backend.setDifferenceAggregationEnabled(enabled);
    }
}

bool rpDifferenceEvaluationEnabled() {
    auto backend = backendOrNull();
    return backend is null ? false : backend.isDifferenceAggregationEnabled();
}

void rpSetDifferenceEvaluationRegion(DifferenceEvaluationRegion region) {
    auto backend = backendOrNull();
    if (backend !is null) {
        backend.setDifferenceAggregationRegion(region);
    }
}

DifferenceEvaluationRegion rpGetDifferenceEvaluationRegion() {
    auto backend = backendOrNull();
    return backend is null ? DifferenceEvaluationRegion.init
                           : backend.getDifferenceAggregationRegion();
}

bool rpEvaluateDifference(uint sourceTexture, int viewportWidth, int viewportHeight) {
    auto backend = backendOrNull();
    if (backend is null) return false;
    return backend.evaluateDifferenceAggregation(sourceTexture, viewportWidth, viewportHeight);
}

bool rpFetchDifferenceResult(out DifferenceEvaluationResult result) {
    auto backend = backendOrNull();
    if (backend is null) {
        result = DifferenceEvaluationResult.init;
        return false;
    }
    return backend.fetchDifferenceAggregationResult(result);
}
