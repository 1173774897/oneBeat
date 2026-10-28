// Real production PCM and feedback driven by ideal simulated hardware clocks.
// Run with Node and the DevEco typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const { fixture, RATE } = require('./metronome-start-timing.cjs');

(async () => {
  const results = [];
  for (const bpm of [40, 60, 120, 240]) {
    for (const skewPpm of [100, 500, 1000, -1000]) {
      const h = fixture({ compensationMs: 45, queueMs: 100 });
      const e = h.engine;
      const origin = h.now;
      e.setOffsetMs(0, skewPpm, h.now + 15000);
      assert.equal(e.phaseCorrectionEnabled, true, 'Long-running PCM must exercise the production default');
      e.setBpm(bpm, 4);
      await e.scheduleFromLeaderStart(origin + 650, 0, 0);
      await h.fireDueTimers();
      h.advanceKeepAlive(650);
      const beatMs = 60000 / bpm;
      const beats = Math.round(600000 / beatMs);
      const snapshots = [];
      let maxResidualMs = 0;
      let maxAudibleErrorMs = 0;
      for (let i = 1; i <= beats; i++) {
        h.advanceKeepAlive(beatMs);
        e.setOffsetMs((h.now - origin) * skewPpm / 1e6, skewPpm, h.now + 15000);
        e.checkAudioProgress(h.now);
        const residualMs = e.measurePhaseErrorFrames() * 1000 / RATE;
        const audibleErrorMs = e.readAudioPlayheadMs(h.now) - e.transportElapsedAt(h.now);
        assert.ok(Number.isFinite(audibleErrorMs), 'Every observation must use a valid actual PCM playhead');
        maxAudibleErrorMs = Math.max(maxAudibleErrorMs, Math.abs(audibleErrorMs));
        maxResidualMs = Math.max(maxResidualMs, Math.abs(residualMs));
        if (i === Math.round(beats / 2) || i === beats) {
          snapshots.push({ elapsedMs: h.now - origin, residualMs,
            submittedCorrectionMs: e.phaseCorrectionSubmittedFrames * 1000 / RATE,
            pendingFrames: e.phaseCorrectionFrames,
            clockAdjustmentMs: e.transportClockAdjustmentAt(h.now) });
        }
      }
      const result = { bpm, skewPpm, maxResidualMs, maxAudibleErrorMs, snapshots };
      results.push(result);

    }
  }
  const failures = results.filter(r => r.maxResidualMs > 2.5 || r.maxAudibleErrorMs > 5);
  assert.equal(failures.length, 0,
    'Continuous ideal timestamps plus real quiet PCM must keep admitted ±1000 ppm bounded to 2.5 ms across 40–240 BPM. ' +
    JSON.stringify(failures.map(({bpm,skewPpm,maxResidualMs,maxAudibleErrorMs})=>({bpm,skewPpm,maxResidualMs,maxAudibleErrorMs}))));
  console.log('PASS phase drift: 16 ten-minute PCM cases, 40–240 BPM, 100/500/±1000 ppm; maximum simulated audible error ' +
    Math.max(...results.map(r => r.maxAudibleErrorMs)).toFixed(3) + ' ms; not hardware/acoustic certification');
})().catch(error => { console.error(error); process.exitCode = 1; });
