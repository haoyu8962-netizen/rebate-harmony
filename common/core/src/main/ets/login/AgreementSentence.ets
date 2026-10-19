/** 协议链接在原句中的 UTF-16 半开区间（BR-ID-04、G16）。Core 不依赖 DesignSystem。 */
export class AgreementSpan {
  readonly type: string;
  readonly start: number;
  readonly end: number;

  constructor(type: string, start: number, end: number) {
    this.type = type;
    this.start = start;
    this.end = end;
  }
}

/** 保留字典原句；按声明顺序取首次命中，先出现的声明优先占用区间，再按文本位置排序。 */
export class AgreementSentence {
  readonly text: string;
  readonly spans: AgreementSpan[];
  readonly accessibilityText: string;

  private constructor(text: string, spans: AgreementSpan[]) {
    this.text = text;
    this.spans = spans;
    this.accessibilityText = text;
  }

  static of(text: string, links: Map<string, string>): AgreementSentence {
    const spans: AgreementSpan[] = [];
    links.forEach((label: string, type: string): void => {
      const start: number = label.length === 0 ? -1 : text.indexOf(label);
      if (start < 0) {
        return;
      }
      const end: number = start + label.length;
      if (spans.some((span: AgreementSpan): boolean => start < span.end && end > span.start)) {
        return;
      }
      spans.push(new AgreementSpan(type, start, end));
    });
    spans.sort((left: AgreementSpan, right: AgreementSpan): number => left.start - right.start);
    return new AgreementSentence(text, spans);
  }
}

/** 主按钮按触发动作命名；继续输入验证码同样用 get_code（G06、G10）。 */
export class AgreementConfirmKeys {
  readonly titleKey: string = 'login.agree_confirm.title';
  readonly bodyKey: string;
  readonly primaryKey: string;
  readonly secondaryKey: string = 'login.agree_confirm.btn_disagree';

  private constructor(action: string, huaweiTerms: boolean) {
    this.bodyKey = huaweiTerms ? 'login.agree_confirm.body_huawei' :
      (action === 'oauth' ? 'login.agree_confirm.body_oauth' : 'login.agree_confirm.body');
    this.primaryKey = action === 'get_code' ? 'login.agree_confirm.btn_get_code' : 'login.agree_confirm.btn_login';
  }

  /** 通用向量保持原键；华为组件的确认显式加上认证协议正文。 */
  static of(action: string, huaweiTerms: boolean = false): AgreementConfirmKeys {
    return new AgreementConfirmKeys(action, huaweiTerms);
  }
}
