// Runs the production page's management, delete, bookmark and navigation methods.
const assert = require('node:assert/strict');
const { loadPage, harness, clip, flush } = require('./recording-page-flow.cjs');
const plain = value => JSON.parse(JSON.stringify(value));
const first = { ...clip, durationMs: 60000, createdAt: new Date(2026, 9, 22, 17, 13).getTime() };
const second = { ...first, id: 'clip-2', path: '/private/second.mp4' };
const third = { ...first, id: 'clip-3', path: '/private/third.mp4' };
function setup(options = {}, clips = [first, second, third]) {
  const h = harness(options);
  h.controller.state = 'paused';
  h.setClips(clips);
  const page = loadPage('RecordingLibraryPage', h.context);
  page.clips = clips.slice(); page.selectedId = clips[0]?.id ?? '';
  return { ...h, page };
}

async function main() {
  {
    const h = setup(), p = h.page;
    assert.equal(p.dateLabel(first.createdAt), '2026年10月22日');
    assert.equal(p.timeLabel(first.createdAt), '17:13');
    assert.deepEqual(plain(p.clipRows().map(row => row.map(item => item.id))), [[first.id, second.id], [third.id]]);
    p.pageScroller.scrollTo({ xOffset: 0, yOffset: 700, animation: false });
    p.previewTimeSeconds = 17; p.previewPlaying = true;
    p.enterManagement(); p.restorePendingScroll();
    assert.equal(p.managing, true); assert.equal(p.previewPlaying, false);
    assert.equal(p.pageScroller.currentOffset().yOffset, 0);
    assert.equal(h.trace.includes('pause-practice'), false, 'Management never pauses the room transport');
    p.activateClipCard(second);
    assert.equal(p.selectedId, first.id, 'Management selection is independent of preview selection');
    assert.deepEqual(plain(p.managementSelection), [second.id]);
    p.activateClipCard(second); assert.equal(p.managementSelection.length, 0);
    p.toggleSelectAll(); assert.equal(p.allManagementSelected(), true);
    p.toggleManagementSelection(second.id); assert.equal(p.allManagementSelected(), false);
    p.toggleSelectAll(); assert.equal(p.managementSelection.length, 3);
    p.toggleSelectAll(); assert.equal(p.managementSelection.length, 0);
    assert.equal(p.onBackPress(), true); assert.equal(p.managing, false);
    p.restorePendingScroll(); assert.equal(p.pageScroller.currentOffset().yOffset, 700);
    p.previewPrepared(first.id, first.path); p.previewProgress(first.id, first.path, 17);
    assert.equal(p.previewTimeSeconds, 17); assert.equal(p.previewLoading, false);
    assert.equal(h.trace.includes('seek-preview:17:accurate'), true);
    assert.equal(h.trace.includes('start-preview'), false, 'Finishing management restores the bookmark without autoplay');
    p.scrollToPreview(); assert.equal(p.pageScroller.currentOffset().yOffset, 0);
    assert.equal(h.trace.at(-1), 'scroll:0:true');
  }
  {
    const h = setup(), p = h.page;
    p.requestDeleteClip(second.id); assert.equal(p.deleteConfirmVisible, false, 'Normal browsing has no delete action');
    p.enterManagement(); p.toggleManagementSelection(first.id);
    p.requestDeleteClip(second.id);
    assert.equal(p.deleteConfirmVisible, true);
    assert.deepEqual(plain(p.deleteClipIds), [second.id]);
    assert.deepEqual(plain(p.managementSelection), [first.id], 'The small cross does not alter selection');
    p.toggleSelectAll(); assert.equal(p.managementSelection.length, 1, 'Confirmation freezes the target selection');
    assert.equal(p.onBackPress(), true); assert.equal(p.managing, true);
    assert.equal(p.deleteConfirmVisible, false); assert.equal(p.managementSelection.length, 1);
    await p.deleteSelected();
    assert.equal(h.trace.some(item => item.startsWith('remove:')), false, 'A stale click after cancelling cannot delete a work');
    p.requestDeleteClip(second.id); await p.deleteSelected();
    assert.equal(p.managing, true); assert.equal(p.selectedId, first.id);
    assert.deepEqual(plain(p.managementSelection), [first.id]);
    assert.deepEqual(plain(p.clips.map(item => item.id)), [first.id, third.id]);
    assert.ok(h.trace.indexOf(`remove:${second.id}`) < h.trace.indexOf(`dismiss:${second.id}`));
  }
  {
    const h = setup({ removeFailureIds: [second.id] }), p = h.page;
    p.enterManagement(); p.toggleSelectAll(); p.requestBatchDelete(); await p.deleteSelected();
    assert.equal(p.managing, true); assert.deepEqual(plain(p.managementSelection), [second.id]);
    assert.deepEqual(plain(p.clips.map(item => item.id)), [second.id]);
    assert.equal(h.notices.at(-1), '已删除 2 段，1 段未完成，可重试');
    assert.equal(h.trace.includes(`dismiss:${second.id}`), false, 'A retained record keeps its pending share metadata');
    p.exitManagement(); assert.equal(p.selectedId, second.id); assert.equal(p.previewTimeSeconds, 0);
    assert.equal(p.previewPlaying, false, 'A removed preview falls back to a remaining work without autoplay');
  }
  {
    const h = setup({ removeCleanupFailureIds: [second.id] }), p = h.page;
    p.enterManagement(); p.toggleSelectAll(); p.requestBatchDelete(); await p.deleteSelected();
    assert.equal(p.managing, false); assert.equal(p.clips.length, 0);
    assert.equal(p.managementSelection.length, 0);
    assert.equal(h.notices.at(-1), '已删除 3 段作品', 'An already-committed removal is not presented as retryable');
  }
  {
    const h = setup(), p = h.page;
    p.renderingAudio = true; p.enterManagement(); assert.equal(p.managing, false);
    p.renderingAudio = false; p.busy = true; p.enterManagement(); assert.equal(p.managing, false);
    p.busy = false; p.enterManagement(); p.requestBatchDelete(); assert.equal(p.deleteConfirmVisible, false);
    p.toggleSelectAll(); p.requestBatchDelete();
    let release; const gate = new Promise(resolve => { release = resolve; });
    const remove = h.context.RecordingRepository.remove;
    let calls = 0;
    h.context.RecordingRepository.remove = async id => { calls++; await gate; return remove(id); };
    const pending = p.deleteSelected(); await flush();
    await p.deleteSelected(); p.exitManagement();
    assert.equal(calls, 1, 'Repeated confirmation cannot issue a duplicate file deletion');
    assert.equal(p.managing, true, 'Management cannot close while deletion is running');
    release(); await pending; assert.equal(calls, 3); assert.equal(p.managing, false);
  }
  {
    const h = setup(), p = h.page;
    h.controller.state = 'playing'; p.enterManagement(); p.exitManagement();
    assert.equal(p.previewContinuation, undefined, 'Active team playback cannot instantiate a resuming preview');
    assert.equal(h.trace.includes('pause-practice'), false);
    assert.equal(h.trace.includes('start-preview'), false);
    const empty = setup({}, []).page; empty.enterManagement(); assert.equal(empty.managing, false);
  }
  {
    const team = { ...third, scope: 'team' };
    const h = setup({}, [first, second, team]), p = h.page;
    p.scope = 'team'; p.refresh(); p.enterManagement(); p.toggleSelectAll(); p.requestBatchDelete();
    p.onPageHide(); await p.deleteSelected();
    p.onPageShow();
    assert.equal(p.managing, false, 'Returning after the last background deletion shows a clean empty state');
    assert.equal(p.clips.length, 0);
    assert.equal(h.context.RecordingRepository.list('solo').length, 2, 'Team management cannot delete solo works');
  }
  {
    const h = setup(), p = h.page;
    p.pageScroller.scrollTo({ xOffset: 0, yOffset: 520, animation: false });
    p.activateClipCard(third);
    assert.equal(p.selectedId, third.id);
    assert.equal(p.pageScroller.currentOffset().yOffset, 0, 'Switching preview scrolls to the top video area');
    assert.equal(h.trace.at(-1), 'scroll:0:true');
  }
  console.log('PASS recording management: two-column grouping, dated cards, top scroll, independent multi-select, single/batch confirmation, failure/retry, index commit semantics, paused bookmark restoration, empty state and room-audio isolation');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
