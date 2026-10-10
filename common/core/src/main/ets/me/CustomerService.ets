// APP-12 统一客服出口（G20；BR-ID-04 细则「未安装微信时」、BR-ID-33 细则、AC-S1-88 ④、AC-S1-134 ④）。三端 Core 一个入口 open(fromRoute)，
// App 层提供界面（三张半屏）。链接原样取 /v1/config.kf.url，不拼 uid、手机号、device_id、邀请码、令牌、订单号、商品链接与发起页路由名；
// 同一台设备上两个账号从同一页打开，链接逐字相同。经系统打开外部链接，不在 App 内 WebView 加载。复制客服链接走 APP-07 统一写入口。
// 桥 cs.open（APP-14）可复用 open（返回是否已拉起）。
import { CsEntryDecision, CsLink } from './MePresentation';
import { MeRecord } from './MeJson';

/** 客服出口用到的 App 能力。 */
export interface CustomerServicePorts {
  /** /v1/config.kf.url（当前 → LKG → 包内；没有为 null）。 */
  kfUrl(): string | null;

  /** 微信已装检测：yes / no / unknown（只查生成物登记的查询项；鸿蒙 query_schemes 为空，一律 unknown）。 */
  wechatInstalled(): string;

  /** 经系统打开外部链接；返回是否拉起成功。 */
  openExternal(url: string): Promise<boolean>;

  /** APP-07 统一剪贴板写入口（先记自写 hash 并确认落盘，记录失败就不写）；返回是否写成。 */
  copy(text: string): Promise<boolean>;

  /** 经 Router 打开帮助中心（Help）。 */
  openHelp(): void;

  /** 显示（或替换）客服半屏：decision 为 CsEntryDecision.of 的结果。 */
  present(decision: MeRecord): void;

  /** 关闭客服半屏。 */
  dismiss(): void;
}

export class CustomerServiceEntry {
  private readonly ports: CustomerServicePorts;
  /** 当前半屏的决策（同一时刻只一张）。 */
  private current: MeRecord | null = null;

  constructor(ports: CustomerServicePorts) {
    this.ports = ports;
  }

  /** 客服链接：原样 kf.url（不拼账号与发起页）。没有或不是 https 为 null。 */
  link(fromRoute: string): string | null {
    const kf: string | null = this.ports.kfUrl();
    if (kf === null || !CsEntryDecision.httpsUrl(kf)) {
      return null;
    }
    const noAccount: MeRecord = {};
    return CsLink.build(kf, fromRoute, noAccount);
  }

  /** 打开客服出口：按 kf 与微信已装检测选半屏（未装微信不直接打开链接）。 */
  open(fromRoute: string): MeRecord {
    const decision: MeRecord = CsEntryDecision.of(this.link(fromRoute), this.ports.wechatInstalled(), null);
    this.current = decision;
    this.ports.present(decision);
    return decision;
  }

  get decision(): MeRecord | null {
    return this.current;
  }

  /** 【打开微信】/【重试】：经系统打开 kf.url；拉不起 → CsOpenFailed（【重试】【复制客服链接】【去帮助中心】）。返回是否已拉起。 */
  async openWechat(fromRoute: string): Promise<boolean> {
    const url: string | null = this.link(fromRoute);
    if (url === null) {
      return false;
    }
    let opened: boolean = false;
    try {
      opened = await this.ports.openExternal(url);
    } catch (e) {
      opened = false;
    }
    if (opened) {
      this.current = null;
      this.ports.dismiss();
      return true;
    }
    const failed: MeRecord = CsEntryDecision.of(url, this.ports.wechatInstalled() === 'no' ? 'unknown' :
      this.ports.wechatInstalled(), 'failed');
    this.current = failed;
    this.ports.present(failed);
    return false;
  }

  /** 【复制客服链接】：复制的就是 kf.url 原串。 */
  copyLink(fromRoute: string): Promise<boolean> {
    const url: string | null = this.link(fromRoute);
    return url === null ? Promise.resolve(false) : this.ports.copy(url);
  }

  /** 【去帮助中心】/【先看看帮助中心】。 */
  goHelp(): void {
    this.current = null;
    this.ports.dismiss();
    this.ports.openHelp();
  }

  close(): void {
    this.current = null;
    this.ports.dismiss();
  }
}
