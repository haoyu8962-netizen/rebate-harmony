// 执行正式 r2 UiTest 原函数；平台为替身，TabBar 回调为产品原代码。
// 仅验证用例会拦住错误结果，不能代替真实系统 Tabs 事件调度及设备验收。
const assert = require('assert/strict');
const { createTabBar, mutate } = require('./check-r2-tabbar.cjs');

module.exports = async ({ cases, driver, delegator }) => {
  const test = cases.find(test => test.name === 'r2_tabbar_click_veto_sync_and_replaced_selected_entry');
  assert.ok(test);
  for (const mutation of ['', 'legacy-will-only', 'skip-selected', 'double-callback', 'sync-callback', 'skip-replaced', 'timer-dedup']) {
    const bar = createTabBar(mutation ? mutate(mutation) : undefined);
    let accepted = true;
    let calls = 0;
    let last = -1;
    let entry = '';
    function reset() {
      bar.items = [{ label: '首页' }, { label: '订单' }, { label: '我的' }];
      bar.selectedIndex = 0;
      accepted = true; calls = 0; last = -1; entry = '';
    }
    reset();
    bar.onSelect = index => {
      calls++; last = index; entry = bar.items[index].label;
      if (accepted) bar.selectedIndex = index;
    };
    const lookup = selector => {
      if (selector.textValue) {
        assert.equal(selector.parent?.typeValue, 'TabBar');
        const index = bar.items.findIndex(item => item.label === selector.textValue);
        if (index < 0) return undefined;
        return { click: async () => {
          const previous = bar.selectedIndex;
          bar.click(index);
          if (index !== previous) {
            await new Promise(resolve => setTimeout(resolve, 25));
            bar.willChange(previous, index);
          }
        } };
      }
      return {
        getText: async () => {
          if (selector.idValue === 'r1-tab-value') return String(bar.selectedIndex);
          assert.equal(selector.idValue, 'r2-tab-events');
          return calls + '/' + last + '/' + entry;
        },
        click: async () => {
          const id = selector.idValue;
          if (id === 'r1-case-tabs') reset();
          else if (id === 'r2-tab-hold') accepted = false;
          else if (id === 'r2-tab-sync-1' || id === 'r2-tab-sync-2') {
            const previous = bar.selectedIndex;
            bar.selectedIndex = Number(id.slice(-1));
            bar.willChange(previous, bar.selectedIndex);
          } else if (id === 'r2-tab-replace') {
            bar.items = [{ label: '首页' }, { label: '搜索' }, { label: '我的' }];
          } else assert.fail('unexpected fixture action: ' + id);
        },
      };
    };
    driver({ findComponent: async selector => lookup(selector), waitForComponent: async selector => lookup(selector),
      waitForIdle: async () => true, delayMs: async () => {} });
    delegator({ startAbility: async want => {
      assert.deepEqual(want, { bundleName: 'com.couli.hm', moduleName: 'entry_test', abilityName: 'Ds02R1Ability' });
    } });
    if (mutation) await assert.rejects(test.fn, assert.AssertionError, mutation);
    else {
      await test.fn();
      assert.equal(calls, 3);
      assert.equal(last, 1);
      assert.equal(entry, '搜索');
    }
    console.log('REFERENCE_ONLY r2 formal UiTest with real product callbacks: ' + (mutation ? 'KILLED ' + mutation : 'baseline passed'));
  }
};
