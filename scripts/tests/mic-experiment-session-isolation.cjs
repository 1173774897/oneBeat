const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const root = path.join(__dirname, '../..');
const sessionSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/app/AppSession.ets'), 'utf8');

function between(source, start, end) {
  const begin = source.indexOf(start), finish = source.indexOf(end, begin);
  assert.ok(begin >= 0 && finish > begin, `Expected real method boundary ${start}`);
  return source.slice(begin, finish);
}

function compile(source) {
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}

// Exercise the actual static ownership predicate and reset lifecycle without
// constructing session engines or importing native networking on a host machine.
const business = `export class AppSession {
  private static instance: AppSession | undefined = undefined;
  private static retiringSession: AppSession | undefined = undefined;
  private static resetOperation: Promise<void> | undefined = undefined;
  ${between(sessionSource, '  static get():', '  static createLeader(')}
  ${between(sessionSource, '  static async reset():', '  /** Wait only for old-session cleanup')}
}`;
const storageWrites = [];
const context = { exports: {}, AppStorage: { setOrCreate: (key, value) => storageWrites.push({ key, value }) } };
vm.runInNewContext(compile(business), context);
const Session = context.exports.AppSession;

const homeSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const homeBusiness = `export class Home {
  ${between(homeSource, '  private openMicExperiment():', '  private goTeam():')}
}`;
let recordingState = 'idle';
const routes = [], notices = [];
const homeContext = { exports: {}, AppSession: Session,
  RecordingCoordinator: { getSnapshot: () => ({ state: recordingState }) },
  router: { pushUrl: value => routes.push(value) }, showUserNotice: value => notices.push(value) };
vm.runInNewContext(compile(homeBusiness), homeContext);
const home = new homeContext.exports.Home();

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

(async () => {
  for (let mask = 0; mask < 8; mask++) {
    Session.instance = mask & 1 ? { name: 'live' } : undefined;
    Session.retiringSession = mask & 2 ? { name: 'retiring' } : undefined;
    Session.resetOperation = mask & 4 ? Promise.resolve() : undefined;
    const before = [Session.instance, Session.retiringSession, Session.resetOperation];
    assert.equal(Session.hasLiveOrRetiringSession(), mask !== 0,
      `All three ownership fields independently block experiments: ${mask}`);
    assert.equal(Session.get(), before[0], 'get() retains its active-instance contract');
    assert.equal(Session.instance, before[0]);
    assert.equal(Session.retiringSession, before[1]);
    assert.equal(Session.resetOperation, before[2], 'The predicate must not mutate or await ownership');
    const count = routes.length;
    home.openMicExperiment();
    assert.equal(routes.length - count, mask === 0 ? 1 : 0,
      'The real home entry blocks live, retiring and in-flight-reset ownership');
  }

  Session.instance = undefined; Session.retiringSession = undefined; Session.resetOperation = undefined;
  for (const state of ['recording', 'saving', 'preparing']) {
    recordingState = state;
    const count = routes.length; home.openMicExperiment();
    assert.equal(routes.length, count, 'Formal recording must remain isolated even without a session');
  }
  for (const state of ['idle', 'failed']) {
    recordingState = state;
    const count = routes.length; home.openMicExperiment();
    assert.equal(routes.length, count + 1);
    assert.equal(routes.at(-1).url, 'pages/MicCaptureExperimentPage');
  }

  const release = deferred();
  let shutdownCount = 0;
  const previous = { shutdown: () => { shutdownCount++; return release.promise; } };
  Session.instance = previous;
  const first = Session.reset();
  assert.equal(Session.get(), undefined, 'The public active instance disappears before shutdown completes');
  assert.equal(Session.retiringSession, previous);
  assert.notEqual(Session.resetOperation, undefined);
  assert.equal(Session.hasLiveOrRetiringSession(), true,
    'The reset window remains isolated while the old renderer and route observer may still exist');
  const second = Session.reset();
  assert.equal(shutdownCount, 1, 'Concurrent resets share one shutdown operation');
  const routeCount = routes.length; home.openMicExperiment(); assert.equal(routes.length, routeCount);
  release.resolve(); await first; await second;
  assert.equal(Session.hasLiveOrRetiringSession(), false, 'Only completed shutdown releases the isolation boundary');
  assert.equal(Session.retiringSession, undefined); assert.equal(Session.resetOperation, undefined);

  const failing = { shutdown: async () => { throw new Error('native audio release failed'); } };
  Session.instance = failing;
  await assert.rejects(Session.reset(), /release failed/);
  assert.equal(Session.get(), undefined); assert.equal(Session.resetOperation, undefined);
  assert.equal(Session.retiringSession, failing);
  assert.equal(Session.hasLiveOrRetiringSession(), true, 'Failed cleanup retains the production ownership boundary');
  failing.shutdown = async () => {};
  await Session.reset();
  assert.equal(Session.hasLiveOrRetiringSession(), false, 'A successful retry can release the retired session');
  assert.ok(storageWrites.some(item => item.key === 'lastTransportMessage' && item.value === ''));
  assert.ok(notices.length > 0);

  console.log('PASS MIC experiment session isolation: real three-field predicate, home entry, in-flight reset, concurrent shutdown, failed retirement and cleanup retry');
})().catch(error => { console.error(error); process.exitCode = 1; });
