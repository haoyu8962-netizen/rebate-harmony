import { hapTasks, OhosAppContext, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { hvigor, HvigorNode, HvigorPlugin } from '@ohos/hvigor';

/**
 * 测试深链 scheme（APP-02a；正式 scheme 与 l. 子域未定，needs N-05）。
 * 只在 product=staging（Debug / Staging）时给 EntryAbility 加一条 skills；product=default（Release）不声明，
 * 免得占位 scheme 进正式包（tools/ci/release-scan.sh 把它列为 Release 禁止项、Debug / Staging 必须命中）。
 * module.json5 本身不按 target 区分，所以在这里构建期改写本模块的 module.json 选项，不改源文件。
 * App 侧只认的 scheme 在 src/staging/ets/variant/BuildVariant.ets（DeepLinkConfig），两处取值要一致。
 */
const DEBUG_DEEP_LINK_SCHEME: string = 'couli-debug';
const DEBUG_PRODUCT: string = 'staging';
const ENTRY_ABILITY: string = 'EntryAbility';

function debugDeepLinkPlugin(): HvigorPlugin {
  return {
    pluginId: 'couliDebugDeepLinkPlugin',
    apply(node: HvigorNode): void {
      hvigor.nodesEvaluated(() => {
        const appContext = hvigor.getRootNode().getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
        if (appContext.getCurrentProduct().getProductName() !== DEBUG_PRODUCT) {
          return;
        }
        const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
        const moduleJson = hapContext.getModuleJsonOpt();
        const ability = (moduleJson.module.abilities ?? []).find((a) => a.name === ENTRY_ABILITY);
        if (ability === undefined) {
          throw new Error('module.json5 里找不到 ' + ENTRY_ABILITY + '，无法声明测试深链 scheme');
        }
        const skills = ability.skills ?? [];
        const declared = skills.some((s) => (s.uris ?? []).some((u) => u.scheme === DEBUG_DEEP_LINK_SCHEME));
        if (!declared) {
          skills.push({
            actions: ['ohos.want.action.viewData'],
            uris: [{ scheme: DEBUG_DEEP_LINK_SCHEME, host: 'r' }]
          });
          ability.skills = skills;
          hapContext.setModuleJsonOpt(moduleJson);
        }
      });
    }
  };
}

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [debugDeepLinkPlugin()] /* Custom plugin to extend the functionality of Hvigor. */
}
