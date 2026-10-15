const assert = require('node:assert/strict');
const fs = require('node:fs');

const engine = fs.readFileSync('entry/src/main/ets/audio/MetronomeEngine.ets', 'utf8');
const calibrator = fs.readFileSync('entry/src/main/ets/audio/MicLoopbackCalibrator.ets', 'utf8');
const page = fs.readFileSync('entry/src/main/ets/pages/MicLoopbackCalibrationPage.ets', 'utf8');
const persistence = fs.readFileSync('entry/src/main/ets/store/AudioLatencyPersistence.ets', 'utf8');
const session = fs.readFileSync('entry/src/main/ets/app/AppSession.ets', 'utf8');
const outputMonitor = fs.readFileSync('entry/src/main/ets/audio/AudioOutputMonitor.ets', 'utf8');

assert.match(engine, /presentationMonoMs:\s*number/,
  'Calibration signal timing must expose the renderer-presentation anchor');
assert.match(engine, /LATENCY_TYPE_HARDWARE/,
  'Input calibration must subtract only latency downstream of the presentation frame');
assert.match(engine, /submitToPresentationMs=/,
  'Submit queue lead should remain observable without becoming the calibration anchor');
assert.match(engine, /clock === undefined[\s\S]*throw new Error\('未取得稳定的音频硬件时间戳/,
  'Mic calibration must fail closed instead of guessing an unknown presentation queue');
assert.match(engine, /readStableCalibrationClock/,
  'Mic calibration must validate a stable hardware frame clock');
assert.match(engine, /observedRateHz[\s\S]*MAX_RATE_ERROR_RATIO/,
  'Mic calibration must reject a hardware frame clock advancing at the wrong rate');
assert.match(engine, /getUptime\(systemDateTime\.TimeType\.STARTUP,\s*true\)\s*\/\s*1000000/,
  'Calibration clock conversion must use nanosecond uptime precision');
assert.match(engine, /waitForCalibrationFrameCrossing/,
  'Calibration must confirm presentation after the hardware playhead crosses the signal');
assert.match(engine, /current\.framePos\s*>=\s*targetFrame/,
  'Calibration crossing must use the raw timestamped frame position');
assert.match(engine, /timestampMonoMs\s*-\s*[\s\S]*framePos\s*-\s*targetFrame/,
  'Actual presentation must be back-interpolated from a post-crossing timestamp');
assert.doesNotMatch(engine, /presentationMonoMs\s*=\s*now\s*\+\s*\(targetFrame\s*-\s*playedFrames\)/,
  'Calibration must not turn renderer query time into a presentation timestamp');
assert.doesNotMatch(engine, /const fallbackPlayedFrames/,
  'Mic calibration must not reintroduce the submit queue through a wall-clock fallback');
assert.match(engine, /calibrationRouteResetPending/,
  'The first probe after an SPK/BT switch must rebuild the calibration frame epoch');
assert.match(engine, /await renderer\.flush\(\)/,
  'A same-renderer mic clock reset must flush the physical queue before zeroing counters');
assert.match(engine, /routeReset[\s\S]*await renderer\.release\(\);[\s\S]*renderer = await this\.createRenderer\(\)/,
  'A route-changing mic calibration must rebuild the renderer and its frame epoch');
assert.match(engine, /micCalibrationRendererRebuildPending[\s\S]*requireExactCalibrationClock/,
  'Playback warm-up must not consume the mic-only route rebuild requirement');
assert.match(engine, /calibrationOperation[\s\S]*scheduleCalibrationSignalExclusive/,
  'One mic signal transaction must finish before the next can overwrite it');
assert.match(engine, /interface PendingCalibrationSignal[\s\S]*fullySubmitted:\s*boolean/,
  'A scheduled chirp must retain identity until its complete tail is submitted');
assert.match(engine, /this\.renderer\s*!==\s*created\s*\|\|\s*this\.rendererEpoch\s*!==\s*rendererEpoch/,
  'A callback from a released renderer must not advance the replacement stream');
assert.match(calibrator, /timing\.presentationMonoMs/,
  'Persistent mic probes must analyze against the renderer-presentation timestamp');
assert.match(calibrator, /captureUntilMonoMs\s*=\s*timing\.presentationMonoMs[\s\S]*CHIRP_DURATION_MS/,
  'Probe capture must last through the complete chirp relative to presentation');
assert.match(calibrator, /last\.latencyMs\s*-\s*last\.hardwareLatencyMs/,
  'Input calibration must subtract the matching hardware leg');
assert.match(calibrator, /stableSamples\.length\s*<\s*MIN_VALID_INPUT_RUNS/,
  'Input calibration must require multiple physically valid probes');
assert.match(calibrator, /INPUT_CLUSTER_MAX_SPREAD_MS:\s*number\s*=\s*30/,
  'Input calibration must reject mutually inconsistent probe values');
assert.match(calibrator, /measurementGeneration/,
  'A retry must permanently invalidate the previous asynchronous mic run');
assert.match(calibrator, /appendCapturedBuffer\(buffer,\s*generation,\s*capturer\)/,
  'Capturer callbacks must be bound to the measurement generation that created them');
assert.match(calibrator, /getCurrentInputDevices\(\)/,
  'Mic diagnostics must reveal which physical input device the system selected');
assert.match(calibrator, /getAudioTimestampInfoSync\(\)[\s\S]*clockMinusHeuristicMs=/,
  'Mic diagnostics must compare the capture hardware clock with the callback heuristic');
assert.match(calibrator, /CORR_DIAG_PEAK_GUARD_MS:\s*number\s*=\s*50[\s\S]*rel=\$\{relativeMs/,
  'Correlation diagnostics must expose independent peaks and their offsets from the selected peak');
assert.match(calibrator, /await capturer\?\.release\(\)/,
  'A retry must not begin while the old capturer release is still pending');
assert.match(calibrator, /CORRELATION_CAUSAL_SLACK_MS[\s\S]*findOnsetByCrossCorrelation\(captured,\s*this\.chirp/,
  'Correlation must exclude a previous chirp that predates the current presentation reference');
assert.doesNotMatch(page, /Math\.max\(0,\s*Math\.round\(result\.inputLatencyMs\)\)/,
  'A negative input latency must not be clamped to zero and persisted');
assert.match(page, /measurementToken\+\+;[\s\S]*this\.hasResult\s*=\s*false/,
  'Disconnecting the measured headset must invalidate an unsaved mic result');
assert.match(page, /saveToken\s*!==\s*this\.measurementToken[\s\S]*previousOutputMs/,
  'A route change during persistence must roll back the stale mic result');
assert.match(page, /await saveInputLatencyMs\(measuredInputLatencyMs\);\s*this\.inputLatencyMs\s*=\s*measuredInputLatencyMs/,
  'The page must expose a new input value only after persistence succeeds');
assert.match(persistence, /INPUT_LATENCY_VERSION:\s*number\s*=\s*3/,
  'Old submit/ALL input calibration values must be invalidated');
assert.match(persistence, /Number\.isFinite\(value\)[\s\S]*value\s*>\s*0/,
  'Restoring input calibration must reject zero and non-finite values too');
assert.match(session, /refreshOutputCalibration\(routeChanged\)/,
  'The output-route observer must invalidate the mic calibration epoch');
assert.match(session,
  /if \(routeChanged && this\.micCalibrationActive\)[\s\S]*flushMicCalibrationProbeBoundary\(\);\s*\}\s*else if \(active && !this\.micCalibrationActive\)/,
  'Only mic calibration may rebuild a probe boundary, without racing generic playback warm-up');
assert.match(session,
  /scheduleMicPostCaptureDiagnostics[\s\S]*capturer-released\+\$\{delayMs\}ms[\s\S]*logAfter\(500\)/,
  'Mic diagnostics must observe the retained renderer after the capturer is released');
assert.match(outputMonitor, /identities\.push\(`\$\{type\}:\$\{devices\[i\]\.id\}`\)/,
  'Route identity must distinguish two wireless devices of the same type');
assert.match(session, /previousRouteSignature\s*!==\s*routeSignature/,
  'Mic frame epochs must reset on physical route identity changes, not only wireless booleans');
assert.match(session, /isBuiltInSpeakerActive\(\)/,
  'Input-side calibration must reject wired, USB, and earpiece output routes');
assert.match(engine, /flushCalibrationStreamBetweenProbes/,
  'Input-side probes must reset the renderer queue between runs on the same route');
assert.match(engine,
  /EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP:\s*boolean\s*=\s*false/,
  'Mic experiments must not silently change the user-verified playback frame mapping');
assert.match(engine,
  /if \(EXPERIMENTAL_EXACT_PLAYBACK_FRAME_MAP && this\.calibrationFrameOriginExact[\s\S]*readCalibrationClockSample\(renderer\)[\s\S]*timestampedFrame = sample\.framePos/,
  'An explicitly enabled playback experiment may retain the mic hardware-frame coordinate');
assert.match(engine,
  /calibrationFrameOriginExact[\s\S]*!this\.calibrationRouteResetPending[\s\S]*!this\.micCalibrationRendererRebuildPending/,
  'Exact playback mapping must be abandoned when the physical route epoch becomes dirty');
assert.match(engine,
  /\[OutputPathDiag\][\s\S]*latencyAll=[\s\S]*latencySoftware=[\s\S]*latencyHardware=/,
  'Mic diagnostics must compare all renderer latency components across capture teardown');
assert.match(engine, /rendererEpoch=\$\{this\.rendererEpoch\}[\s\S]*streamId=\$\{this\.rendererStreamId\}/,
  'Output diagnostics must identify whether calibration and production reuse the same renderer epoch');
assert.match(engine, /const playedEstimate = Math\.min\(this\.audioSubmittedFrames, elapsedFrames\)/,
  'Non-mic renderers must retain the elapsed-time mapping fallback');
assert.match(session, /flushMicCalibrationProbeBoundary/,
  'The session must expose the mic calibration probe boundary flush to the calibration page');
assert.match(calibrator, /measureWithPersistentRenderer[\s\S]*probeBoundary/,
  'Headphone loopback must realign the renderer epoch between probes');
assert.match(page, /audioOutputRouteEpoch[\s\S]*onAudioOutputRouteChanged/,
  'An unsaved mic result must be invalidated by any physical output-route change');
assert.match(page, /inputMeasurementToken\s*!==\s*this\.measurementToken/,
  'Input-side results must also be discarded when the output route changes mid-run');

console.log('PASS: mic loopback uses presentation/HARDWARE timing and rejects invalid input calibration');
