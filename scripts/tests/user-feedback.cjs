// Execute the shared feedback policy with a controlled clock and native toast sink.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
let now = 1000;
const notices = [];
const logs = [];
const context = {
  exports: {},
  console: { warn: message => logs.push(message) },
  require(name) {
    if (name === '@kit.ArkUI') return { promptAction: { showToast: args => notices.push(args.message) } };
    assert.equal(name, './MonotonicClock');
    return { MonotonicClock: { nowMs: () => now } };
  }
};
const source = fs.readFileSync('entry/src/main/ets/common/UserFeedback.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
vm.runInNewContext(compiled.outputText, context);
const { showUserNotice, userErrorMessage, isUserCancelled, logUserFailure } = context.exports;

for (const code of [1000500002, 1001860000, 1001502012]) assert.equal(isUserCancelled({ code }), true);
for (const error of [{ code: '1000500002' }, { message: 'user canceled timeout' },
  { code: 1000500001 }, { code: NaN }, new Error('取消失败')]) {
  assert.equal(isUserCancelled(error), false, 'Only verified numeric SDK codes may suppress a failure');
}
showUserNotice('连接失败', 'join');
showUserNotice('连接失败', 'join');
showUserNotice('权限不足', 'join');
showUserNotice('连接失败', 'play');
assert.deepEqual(notices, ['连接失败', '权限不足', '连接失败']);
now += 1999;
showUserNotice('连接失败', 'join');
assert.equal(notices.length, 3);
now++;
showUserNotice('连接失败', 'join');
assert.equal(notices.length, 4, 'Retry feedback must become available after the short repeat window');
now = 1;
showUserNotice('连接失败', 'join');
showUserNotice('   ', 'join');
assert.equal(notices.length, 5, 'Clock reset must not suppress notices forever; empty notices stay silent');
assert.equal(userErrorMessage(new Error('口令不正确或活动已结束'), '兑换失败'), '口令不正确或活动已结束');
assert.equal(userErrorMessage(new Error('附近未找到该房间'), '加入失败'),
  '附近未找到队伍，请确认队长仍在大厅，或改用扫码加入');
assert.equal(userErrorMessage({ code: 1001502001 }, '购买失败'), '请先登录华为账号，再重试');
assert.equal(userErrorMessage({ code: 1001860050 }, '购买失败'), '请先登录华为账号，再重试');
const secret = 'request token=SECRET redemption=PRIVATE purchasePayload=HIDDEN';
assert.equal(userErrorMessage(new Error(secret), '兑换失败，请重试'), '兑换失败，请重试');
assert.equal(userErrorMessage(new Error(secret), ''), '操作未完成，请重试');
logUserFailure('store.redeem', { code: 40922, message: secret, payload: secret });
assert.equal(logs.length, 1);
assert.match(logs[0], /scope=store.redeem code=40922/);
assert.ok(!logs[0].includes('SECRET') && !logs[0].includes('PRIVATE') && !logs[0].includes('HIDDEN'));
console.log('PASS user feedback: scoped repeat suppression, exact SDK cancellation, actionable mapping and redacted diagnostics');
