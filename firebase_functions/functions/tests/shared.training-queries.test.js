const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const {
  detectPlateau,
  detectDeload,
  detectOverreach,
  aggregateToGroup,
  SORT_OPTIONS,
  getRecentWeekStarts,
  computeSeriesSummary,
  normalizeExerciseName,
} = require('../shared/training-queries');
const { ValidationError } = require('../shared/errors');

// ---------------------------------------------------------------------------
// detectPlateau
// ---------------------------------------------------------------------------

describe('detectPlateau', () => {
  test('returns false with fewer than 4 points', () => {
    assert.equal(detectPlateau([{ e1rm_max: 100 }, { e1rm_max: 100 }]), false);
  });

  test('returns false with fewer than 3 e1rm values in last 4', () => {
    const points = [
      { e1rm_max: 100 },
      { e1rm_max: null },
      { e1rm_max: null },
      { e1rm_max: 100 },
    ];
    assert.equal(detectPlateau(points), false);
  });

  test('returns true when e1rm within 2% range', () => {
    const points = [
      { e1rm_max: 100 },
      { e1rm_max: 101 },
      { e1rm_max: 100.5 },
      { e1rm_max: 100.8 },
    ];
    assert.equal(detectPlateau(points), true);
  });

  test('returns false when e1rm varies more than 2%', () => {
    const points = [
      { e1rm_max: 100 },
      { e1rm_max: 110 },
      { e1rm_max: 105 },
      { e1rm_max: 115 },
    ];
    assert.equal(detectPlateau(points), false);
  });
});

// ---------------------------------------------------------------------------
// detectDeload
// ---------------------------------------------------------------------------

describe('detectDeload', () => {
  test('returns false with fewer than 2 points', () => {
    assert.equal(detectDeload([{ volume: 1000 }]), false);
  });

  test('returns true when volume drops > 40%', () => {
    const points = [
      { volume: 1000 },
      { volume: 500 },
    ];
    assert.equal(detectDeload(points), true);
  });

  test('returns false when volume drops < 40%', () => {
    const points = [
      { volume: 1000 },
      { volume: 700 },
    ];
    assert.equal(detectDeload(points), false);
  });

  test('returns false when prev volume is 0', () => {
    const points = [
      { volume: 0 },
      { volume: 500 },
    ];
    assert.equal(detectDeload(points), false);
  });
});

// ---------------------------------------------------------------------------
// detectOverreach
// ---------------------------------------------------------------------------

describe('detectOverreach', () => {
  test('returns false with fewer than 2 points', () => {
    assert.equal(detectOverreach([{ failure_rate: 0.5, avg_rir: 0 }]), false);
  });

  test('returns true with high failure, low RIR, rising volume', () => {
    const points = [
      { failure_rate: 0.4, avg_rir: 0.5, volume: 800 },
      { failure_rate: 0.5, avg_rir: 0.5, volume: 1000 },
    ];
    assert.equal(detectOverreach(points), true);
  });

  test('returns false with low failure rate', () => {
    const points = [
      { failure_rate: 0.1, avg_rir: 0.5, volume: 800 },
      { failure_rate: 0.1, avg_rir: 0.5, volume: 1000 },
    ];
    assert.equal(detectOverreach(points), false);
  });
});

// ---------------------------------------------------------------------------
// aggregateToGroup
// ---------------------------------------------------------------------------

describe('aggregateToGroup', () => {
  test('initializes new group with zeros', () => {
    const groups = new Map();
    const sf = { hard_set_credit: 0, volume: 0, rir: null, is_failure: false, e1rm: null };
    aggregateToGroup(groups, 'chest', sf, 1);
    const agg = groups.get('chest');
    assert.equal(agg.sets, 1);
    assert.equal(agg.volume, 0);
    assert.equal(agg.e1rm_max, null);
  });

  test('accumulates values with weight', () => {
    const groups = new Map();
    aggregateToGroup(groups, 'chest', { hard_set_credit: 1, volume: 100, rir: 2, is_failure: false, e1rm: 80 }, 0.5);
    aggregateToGroup(groups, 'chest', { hard_set_credit: 1, volume: 200, rir: 1, is_failure: true, e1rm: 90 }, 0.5);
    const agg = groups.get('chest');
    assert.equal(agg.sets, 2);
    assert.equal(agg.volume, 150); // (100 * 0.5) + (200 * 0.5)
    assert.equal(agg.rir_count, 2);
    assert.equal(agg.failure_sets, 1);
    assert.equal(agg.e1rm_max, 90);
  });

  test('tracks e1rm_max correctly', () => {
    const groups = new Map();
    aggregateToGroup(groups, 'back', { hard_set_credit: 0, volume: 0, rir: null, is_failure: false, e1rm: 120 }, 1);
    aggregateToGroup(groups, 'back', { hard_set_credit: 0, volume: 0, rir: null, is_failure: false, e1rm: 100 }, 1);
    assert.equal(groups.get('back').e1rm_max, 120);
  });
});

// ---------------------------------------------------------------------------
// SORT_OPTIONS
// ---------------------------------------------------------------------------

describe('SORT_OPTIONS', () => {
  test('contains expected sort modes', () => {
    assert.deepEqual(SORT_OPTIONS, ['date_desc', 'date_asc', 'e1rm_desc', 'volume_desc']);
  });
});

// ---------------------------------------------------------------------------
// getRecentWeekStarts
// ---------------------------------------------------------------------------

describe('getRecentWeekStarts', () => {
  test('returns correct number of weeks', () => {
    const weeks = getRecentWeekStarts(4);
    assert.equal(weeks.length, 4);
  });

  test('returns weeks in ascending order (oldest first)', () => {
    const weeks = getRecentWeekStarts(4);
    for (let i = 1; i < weeks.length; i++) {
      assert.ok(weeks[i] > weeks[i - 1], `${weeks[i]} should be after ${weeks[i - 1]}`);
    }
  });

  test('returns YYYY-MM-DD format strings', () => {
    const weeks = getRecentWeekStarts(2);
    for (const w of weeks) {
      assert.match(w, /^\d{4}-\d{2}-\d{2}$/);
    }
  });
});

// ---------------------------------------------------------------------------
// computeSeriesSummary
// ---------------------------------------------------------------------------

describe('computeSeriesSummary', () => {
  test('returns zeros for empty points', () => {
    const summary = computeSeriesSummary([]);
    assert.equal(summary.total_weeks, 0);
    assert.equal(summary.avg_weekly_sets, 0);
    assert.equal(summary.avg_weekly_volume, 0);
    assert.equal(summary.trend_direction, null);
  });

  test('computes averages correctly', () => {
    const points = [
      { sets: 10, volume: 1000, hard_sets: 8 },
      { sets: 12, volume: 1200, hard_sets: 10 },
    ];
    const summary = computeSeriesSummary(points);
    assert.equal(summary.total_weeks, 2);
    assert.equal(summary.avg_weekly_sets, 11);
    assert.equal(summary.avg_weekly_volume, 1100);
    assert.equal(summary.avg_weekly_hard_sets, 9);
  });

  test('detects increasing trend with 4+ points', () => {
    const points = [
      { sets: 10, volume: 500, hard_sets: 8 },
      { sets: 10, volume: 500, hard_sets: 8 },
      { sets: 10, volume: 1000, hard_sets: 8 },
      { sets: 10, volume: 1000, hard_sets: 8 },
    ];
    const summary = computeSeriesSummary(points);
    assert.equal(summary.trend_direction, 'increasing');
  });

  test('returns null trend_direction with fewer than 4 points', () => {
    const points = [
      { sets: 10, volume: 500, hard_sets: 8 },
      { sets: 10, volume: 1000, hard_sets: 8 },
    ];
    const summary = computeSeriesSummary(points);
    assert.equal(summary.trend_direction, null);
  });
});

// ---------------------------------------------------------------------------
// normalizeExerciseName
// ---------------------------------------------------------------------------

describe('normalizeExerciseName', () => {
  test('lowercases and trims', () => {
    assert.equal(normalizeExerciseName('  Bench Press  '), 'bench press');
  });

  test('replaces hyphens and underscores with spaces', () => {
    assert.equal(normalizeExerciseName('lat-pull_down'), 'lat pull down');
  });

  test('collapses multiple spaces', () => {
    assert.equal(normalizeExerciseName('bench   press'), 'bench press');
  });

  test('returns empty string for null/undefined', () => {
    assert.equal(normalizeExerciseName(null), '');
    assert.equal(normalizeExerciseName(undefined), '');
  });
});

// ---------------------------------------------------------------------------
// ValidationError
// ---------------------------------------------------------------------------

describe('ValidationError', () => {
  test('is an instance of Error', () => {
    const err = new ValidationError('bad input');
    assert.ok(err instanceof Error);
    assert.equal(err.name, 'ValidationError');
    assert.equal(err.message, 'bad input');
  });

  test('carries details', () => {
    const err = new ValidationError('bad input', { validOptions: ['a', 'b'] });
    assert.deepEqual(err.details, { validOptions: ['a', 'b'] });
  });
});
