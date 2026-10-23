// 设施自证：执行正式 UiTest 用例的原函数，输入模拟的平台结果。
// 这不是产品变异实测，也不证明设备渲染/点击已通过。
const assert = require('assert/strict');
const KeyCode = { KEYCODE_A: 2017, KEYCODE_V: 2038, KEYCODE_DEL: 2055, KEYCODE_CTRL_LEFT: 2072 };
let clipboardData = { text: 'previous clipboard' };
const clipboard = {
  hasData: async () => true, getData: async () => clipboardData,
  setData: async data => { clipboardData = data; }, clearData: async () => { clipboardData = undefined; },
};
const pasteboard = { MIMETYPE_TEXT_PLAIN: 'text/plain', createData: (_type, text) => ({ text }), getSystemPasteboard: () => clipboard };
module.exports.platform = { KeyCode, pasteboard };
module.exports.verify = async ({ cases, driver, delegator }) => {
  const scenarios = {
    r1_navbar_system_nodes_and_host_back_interception: ['', 'selfdrawn', 'no-host-callback', 'ignores-host', 'never-pops'],
    r1_filterchip_48vp_disjoint_and_edge_tap: ['', 'late-layout', 'moves-after-first-tap', 'no-reserve', 'overlap', 'edge-misses', 'edge-toggles-neighbor', 'never-stable', 'zero-bounds', 'idle-false', 'layout-transport'],
    r1_readonly_blocks_focused_keyboard_paste_and_clear: ['', 'editable', 'keyboard-edits', 'paste-edits', 'clear-edits', 'input-edits', 'transport-error'],
    r1_share_six_materials_four_columns_at_320vp: ['', 'null-then-ready', 'null-between-reads', 'late-layout', 'count-then-ready', 'nocandidates-once', '99-columns', 'unequal', 'overflow', 'not-square', 'missing', 'null-forever', 'never-stable', 'zero-bounds', 'wrong-parent-width', 'layout-transport'],
  };
  for (const [name, mutations] of Object.entries(scenarios)) {
    for (const mutation of mutations) {
      let mode = '', pushed = false, blocked = true, backs = 0, first = false, second = false, readonly = false;
      let value = '不可修改';
      let idleCount = 0, groupQueries = 0, transientErrors = 0;
      const positive = ['', 'late-layout', 'moves-after-first-tap', 'null-then-ready', 'null-between-reads', 'count-then-ready', 'nocandidates-once'].includes(mutation);
      const moving = () => mutation === 'never-stable' ? idleCount * 3 : mutation === 'late-layout' && idleCount < 4 ? (4 - idleCount) * 10 : mutation === 'moves-after-first-tap' && first ? 40 : 0;
      const shifted = r => ({ ...r, top: r.top + moving(), bottom: r.bottom + moving() });
      const stats = { keyboard: 0, paste: 0, clear: 0, input: 0 };
      const original = clipboardData;
      const bounds = id => shifted(id === 'r1-chip-a' ? { left: 0, right: 48, top: 100, bottom: mutation === 'no-reserve' ? 132 : 148 }
        : id === 'r1-chip-b' ? { left: 0, right: 48, top: mutation === 'overlap' ? 140 : 156, bottom: 204 }
        : { left: 0, right: mutation === 'wrong-parent-width' ? 300 : 320, top: 100, bottom: 300 });
      const click = id => {
        if (id?.startsWith('r1-case-')) { mode = id.slice(8); readonly = false; value = '不可修改'; }
        if (id === 'r1-push') { pushed = true; blocked = true; backs = 0; }
        if (id === 'r1-allow-back') blocked = false;
        if (id === '__NavigationField__BackButton__Back__r1-nav') {
          if (mutation !== 'no-host-callback') backs++;
          if ((!blocked || mutation === 'ignores-host') && mutation !== 'never-pops') pushed = false;
        }
        if (id === 'r1-readonly') readonly = true;
      };
      const lookup = selector => {
        const id = selector.idValue, type = selector.typeValue;
        if (mutation === 'late-layout' && ['r1-chip-a', 'r1-grid'].includes(id) && idleCount < 2) return null;
        if (id === 'r1-destination' && !pushed) return undefined;
        if (['TextInput', 'TextArea'].includes(type) && readonly && mutation !== 'editable') return undefined;
        if (type === 'Text' && selector.textValue && selector.textValue !== value) return undefined;
        return {
          click: async () => click(id),
          getType: async () => id === 'r1-nav' ? (mutation === 'selfdrawn' ? 'Row' : 'Navigation') : 'BackButton',
          getText: async () => id === '__NavigationField__Text__MainTitle__r1-nav' ? '二级页面'
            : id === 'r1-back-count' ? String(backs) : id === 'r1-chip-value' ? first + '/' + second
            : id === 'r1-input-value' ? value + '/0' : value,
          getBounds: async () => { if (mutation === 'layout-transport') throw new Error('LAYOUT_TRANSPORT_ERROR');
            return mutation === 'zero-bounds' ? {left:0,right:0,top:0,bottom:0} : bounds(id); },
          inputText: async () => { stats.input++; if (mutation === 'input-edits') value = 'changed';
            if (mutation === 'transport-error') throw { code: 17000004 }; },
          clearText: async () => { stats.clear++; if (mutation === 'clear-edits') value = ''; },
        };
      };
      delegator({ startAbility: async want => {
        assert.deepEqual(want, { bundleName: 'com.couli.hm', moduleName: 'entry_test', abilityName: 'Ds02R1Ability' });
      } });
      driver({
        findComponent: async selector => lookup(selector), waitForComponent: async selector => lookup(selector),
        waitForIdle: async () => { idleCount++; return mutation !== 'idle-false'; },
        findComponents: async selector => {
          assert.equal(selector.typeValue, 'GridCol');
          groupQueries++;
          if (mutation === 'null-forever' || mutation === 'null-then-ready' && groupQueries <= 2 || mutation === 'null-between-reads' && groupQueries === 2) return null;
          if (mutation === 'nocandidates-once' && transientErrors++ === 0) throw new Error('NoCandidates');
          return Array.from({ length: mutation === 'missing' || mutation === 'count-then-ready' && groupQueries === 1 ? 4 : 6 }, (_v, i) => ({ getBounds: async () => {
            const width = mutation === '99-columns' ? 3 : 74;
            const left = mutation === '99-columns' ? i * 11 : (i % 4) * 82;
            const top = 100 + (mutation === '99-columns' ? 0 : Math.floor(i / 4) * 82);
            return shifted({ left, top, right: left + width + (mutation === 'unequal' && i === 2 ? 5 : 0) +
              (mutation === 'overflow' && i === 3 ? 20 : 0), bottom: top + width + (mutation === 'not-square' ? 5 : 0) });
          } }));
        },
        click: async (x, y) => {
          if (positive) {
            const expected = bounds(first ? 'r1-chip-b' : 'r1-chip-a');
            assert.equal(x, 24); assert.equal(y, expected.top + 2);
            if (mutation === 'late-layout') assert.ok(idleCount >= 4, 'must wait for stationary layout');
          }
          if (mutation === 'edge-misses') return;
          if (!first) first = !first; else second = !second;
          if (mutation === 'edge-toggles-neighbor') second = !second;
        },
        triggerKey: async key => { if (key === KeyCode.KEYCODE_A) { stats.keyboard++; if (mutation === 'keyboard-edits') value = 'a'; }
          else if (key === KeyCode.KEYCODE_DEL && mutation === 'clear-edits') value = ''; },
        triggerCombineKeys: async (_ctrl, key) => {
          if (key === KeyCode.KEYCODE_V) { stats.paste++; if (mutation === 'paste-edits') value = 'DS02_PASTE'; }
        },
      });
      const run = cases.find(test => test.name === name).fn;
      if (!positive) await assert.rejects(run, error => {
        if (mutation === 'null-forever') assert.match(error.message, /DS02_LAYOUT_NOT_STABLE: findComponents=null/);
        if (mutation === 'layout-transport') assert.match(error.message, /LAYOUT_TRANSPORT_ERROR/);
        return true;
      }, name + '/' + mutation);
      else {
        await run();
        if (mutation === 'null-then-ready') assert.equal(groupQueries, 4);
        if (mutation === 'null-between-reads') assert.equal(groupQueries, 4, 'null must reset consecutive-read counter');
        if (name.includes('readonly')) assert.deepEqual(stats, { keyboard: 2, paste: 2, clear: 2, input: 2 });
      }
      assert.equal(clipboardData, original, 'clipboard restoration');
    }
    console.log('REFERENCE_ONLY formal case ' + name + ': ' + mutations.length + ' baseline/transient/negative scenarios checked');
  }
};
