import { taskpool } from '@kit.ArkTS';
import { pcmJobArrayBuffers, PcmRenderJob, PcmRenderResult, renderPcmJob } from './PcmRender';
import { PcmRenderOffload } from './PcmRenderOffload';

/**
 * Runs on a TaskPool worker. Arguments and the result are copied across the
 * thread boundary, so the job must stay plain data (Map/ArrayBuffer/typed
 * arrays/plain objects); class prototypes and engine state are not available.
 */
@Concurrent
function renderPcmJobOnWorker(job: PcmRenderJob): PcmRenderResult {
  return renderPcmJob(job);
}

async function runOnTaskPool(job: PcmRenderJob): Promise<PcmRenderResult> {
  const task = new taskpool.Task(renderPcmJobOnWorker, job);
  // Copy, never transfer: the engine keeps these buffers (see pcmJobArrayBuffers).
  // The result's buffers belong to the worker and are transferred back as usual.
  task.setCloneList(pcmJobArrayBuffers(job));
  // HIGH: the result gates a shared start; it is not background work.
  const result = await taskpool.execute(task, taskpool.Priority.HIGH);
  return result as PcmRenderResult;
}

export function registerPcmRenderTaskPool(): void {
  PcmRenderOffload.register(runOnTaskPool);
}
