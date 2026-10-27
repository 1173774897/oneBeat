import { abilityAccessCtrl, common, Want } from '@kit.AbilityKit';
import * as recordingNative from 'libonebeat_recording.so';
import { AppSession } from '../app/AppSession';
import { RecordingCoordinator } from '../recording/RecordingCoordinator';
import { RecordingRepository } from '../recording/RecordingRepository';
import { MicCaptureExperiment } from './MicCaptureExperiment';
import { RecordingPlaybackObserver } from './RecordingPlaybackObserver';

const PROBE_DURATION_MS: number = 10000;

/** Debug-only, bounded observation of the existing team output; never a transport or calibration command. */
export class TeamAcousticProbe {
  private static active: boolean = false;
  private static generation: number = 0;
  private static experiment: MicCaptureExperiment | undefined = undefined;

  static async handleWant(context: common.UIAbilityContext, want: Want): Promise<void> {
    // Ability Wants are externally supplied. Release builds cannot capture or export
    // private recordings, and debug commands accept no caller-controlled path/duration.
    if (context.applicationInfo.debug !== true) { return; }
    const command = want.parameters?.['onebeatProbe'];
    if (command !== 'mic' && command !== 'snapshot' && command !== 'export') { return; }
    if (TeamAcousticProbe.active) {
      console.info('[TeamAcousticProbe] stage=reject reason=probe-busy');
      return;
    }
    TeamAcousticProbe.active = true;
    const generation = ++TeamAcousticProbe.generation;
    try {
      TeamAcousticProbe.assertRecordingIdle();
      if (command === 'export') {
        const paths = await RecordingRepository.exportLatestTracksForDebug();
        console.info(`[TeamAcousticProbe] stage=export count=${paths.length} paths=${JSON.stringify(paths)}`);
        return;
      }
      const session = AppSession.get();
      if (session === undefined) { throw new Error('no-session'); }
      if (command === 'snapshot') {
        console.info('[TeamAcousticProbe] stage=snapshot data=' +
          JSON.stringify(session.metronome.readMicExperimentPlaybackSnapshot(true)));
        return;
      }
      if (session.controller.state !== 'playing') { throw new Error('team-not-playing'); }
      const tokenId = context.applicationInfo.accessTokenId;
      const permission = abilityAccessCtrl.createAtManager().checkAccessTokenSync(tokenId, 'ohos.permission.MICROPHONE');
      if (permission !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) { throw new Error('microphone-not-granted'); }
      await TeamAcousticProbe.capture(context, session, generation);
    } catch (error) {
      console.warn(`[TeamAcousticProbe] stage=failed reason=${(error as Error).message}`);
    } finally {
      TeamAcousticProbe.experiment = undefined;
      TeamAcousticProbe.active = false;
    }
  }

  /** Background/destroy cancels only this diagnostic capturer, never the team's renderer. */
  static cancel(): void {
    TeamAcousticProbe.generation++;
    TeamAcousticProbe.experiment?.cancel();
  }

  private static assertRecordingIdle(): void {
    const snapshot = RecordingCoordinator.getSnapshot();
    if (snapshot.captureActive || (snapshot.state !== 'idle' && snapshot.state !== 'failed')) {
      throw new Error('recording-busy');
    }
  }

  private static async capture(context: common.UIAbilityContext, session: AppSession,
    generation: number): Promise<void> {
    const experiment = new MicCaptureExperiment();
    TeamAcousticProbe.experiment = experiment;
    let unsafeReason: string = '';
    const assertCurrent = (): void => {
      if (generation !== TeamAcousticProbe.generation || AppSession.get() !== session ||
        session.controller.state !== 'playing') { throw new Error('session-or-transport-changed'); }
      TeamAcousticProbe.assertRecordingIdle();
      if (unsafeReason.length > 0) { throw new Error(unsafeReason); }
    };
    const observer = new RecordingPlaybackObserver((details: boolean) => {
      assertCurrent();
      const snapshot = session.metronome.readMicExperimentPlaybackSnapshot(details);
      if (!snapshot.running || !snapshot.started) { throw new Error('renderer-not-running'); }
      return snapshot;
    }, (): string => session.controller.state, (reason: string): void => {
      unsafeReason = reason;
      experiment.cancel();
    });
    try {
      const initialProblem = observer.start();
      if (initialProblem.length > 0) { throw new Error(initialProblem); }
      console.info(`[TeamAcousticProbe] stage=mic-start durationMs=${PROBE_DURATION_MS}`);
      const result = await experiment.run(context.filesDir, 'mic', {
        snapshot: (): string => {
          assertCurrent();
          // This read must remain passive: raw anchors are recorded alongside
          // production coordinates without refreshing or rebasing either clock.
          return JSON.stringify(session.metronome.readMicExperimentPlaybackSnapshot(false));
        }
      }, PROBE_DURATION_MS);
      assertCurrent();
      const finalProblem = observer.checkpoint('team-acoustic-probe-after');
      if (finalProblem.length > 0) { throw new Error(finalProblem); }
      if (!recordingNative.chmod(result.wavPath, 0o644) || !recordingNative.chmod(result.reportPath, 0o644)) {
        throw new Error('debug-export-failed');
      }
      console.info(`[TeamAcousticProbe] stage=mic-complete frames=${result.totalFrames} ` +
        `sampleRate=${result.sampleRate} channels=${result.channels} peak=${result.peak} ` +
        `wav=${result.wavPath} report=${result.reportPath}`);
    } finally {
      observer.dispose();
    }
  }
}
