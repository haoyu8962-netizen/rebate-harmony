// 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）。tabPosition 只在注释里不算。
import { TabBarItem } from 'designsystem';

export class ShellTab {
  readonly route: string = '';
  readonly label: string = '';
  readonly icon: string = '';
}
const SHELL_TABS: ShellTab[] = [];

export function shellTabItems(agentVisible: boolean = true): TabBarItem[] {
  return SHELL_TABS.map((shown: ShellTab) => {
    return new TabBarItem(shown.label, shown.icon);
  });
}
