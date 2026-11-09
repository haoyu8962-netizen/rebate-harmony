// FU-HM-FEEL-KIT：动效时长与减弱动态的纯逻辑（README §3.3；D10-838 原生不读 motion 令牌）。无 @kit、无资源，进 Logic.ets，本机单测直接测。
// 减弱动态（D10-1163 ①）：取消位移 / 缩放（durationMs 0），透明度淡入保留短时长（fadeMs）。

/** 微交互 / 进出。 */
export enum MotionKind {
  MICRO,
  ENTER
}

/** 按压反馈：回弹 / 背景高亮。减弱动态时回弹退化为高亮。 */
export enum PressKind {
  BOUNCE,
  HIGHLIGHT
}

const DURATION_MICRO_MS: number = 150;
const DURATION_ENTER_MS: number = 250;
/** 减弱动态时淡入保留的短时长（微交互档 100–200）。 */
const REDUCED_FADE_MS: number = 150;

/** 一次动效用什么：动画时长、位移是否置零、淡入时长。 */
export class MotionSpec {
  durationMs: number;
  zeroTranslate: boolean;
  fadeMs: number;

  constructor(durationMs: number, zeroTranslate: boolean, fadeMs: number) {
    this.durationMs = durationMs;
    this.zeroTranslate = zeroTranslate;
    this.fadeMs = fadeMs;
  }
}

export class MotionPolicy {
  static resolve(reduced: boolean, kind: MotionKind): MotionSpec {
    if (reduced) {
      return new MotionSpec(0, true, REDUCED_FADE_MS);
    }
    const duration: number = kind === MotionKind.MICRO ? DURATION_MICRO_MS : DURATION_ENTER_MS;
    return new MotionSpec(duration, false, duration);
  }

  static press(reduced: boolean, kind: PressKind): PressKind {
    return reduced ? PressKind.HIGHLIGHT : kind;
  }
}
