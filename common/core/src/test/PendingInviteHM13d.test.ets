// HM-13d / D10-107 / F-HM-52 写入侧：BR-INV-01、BR-INV-02。
// 共用向量原文在 specs/login-vectors.json.pendingInviteSet，gen.py 转为 LoginVectorsData。
// 最小新增接口：PendingInviteCode.set(raw: string): boolean；InviteField.isValidCode(normalized: string): boolean。
// 后者只判非空的 6 位合法码；InviteField.decide 仍允许空值省略，wireValue 原有行为不变。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, ApiResult, ClipboardController, ClipboardDeps, ClipboardPromptView, ClipboardReadPolicy,
  InviteField, InviteLinkDecision, InviteLinkDispatcher, InviteLinkInput, ManualPasteAction,
  PasteboardPort, PasteOutcome, PendingInviteCode, SearchApiPort
} from '../../Index';
import { LOGIN_VECTORS_JSON } from './LoginVectorsData';

type Scalar = string | boolean | number | null;

interface ValidSetVector {
  raw: string;
  stored: string;
}

interface SetSequenceVector {
  steps: string[];
  stored: string | null;
}

interface PendingSetVectors {
  version: number;
  valid: ValidSetVector[];
  invalid: string[];
  sequences: SetSequenceVector[];
}

interface SetVectorsRoot {
  pendingInviteSet: PendingSetVectors;
}

const OLD_CODE: string = 'K7M2QX';
const NEW_CODE: string = 'T3ST22';
const BAD_CODE: string = 'K7M2Q0';
// 独立的逐步期望：不调用生产 normalize / validator 来计算测试真值，不改共用向量。
const STEP_ACCEPTED: boolean[][] = [[true, false], [true, true], [false]];
const STEP_STORED: (string | null)[][] = [[OLD_CODE, OLD_CODE], [OLD_CODE, NEW_CODE], [null]];

function same(label: string, actual: Scalar, expected: Scalar): void {
  expect(label + ': ' + JSON.stringify(actual)).assertEqual(label + ': ' + JSON.stringify(expected));
}

function setAndCheck(pending: PendingInviteCode, raw: string, accepted: boolean,
  stored: string | null, label: string): void {
  const result: boolean = pending.set(raw);
  const first: string | null = pending.peek();
  const second: string | null = pending.peek();
  same(label + '.stored', first, stored);
  same(label + '.peek does not consume', second, stored);
  same(label + '.set return', result, accepted);
}

class Board implements PasteboardPort {
  text: string | null = null;

  readText(): Promise<string | null> {
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.text = text;
    return Promise.resolve(true);
  }
}

// 仅替换网络端口；若控制器误发请求，调用入口同步记数并直接判红。
class NoRequestApi implements SearchApiPort {
  calls: number = 0;

  request(_request: ApiRequest): Promise<ApiResult> {
    this.calls++;
    throw new Error('HM-13d invite confirmation must not request');
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

class ClipEntry {
  readonly pending: PendingInviteCode = new PendingInviteCode();
  readonly board: Board = new Board();
  readonly api: NoRequestApi = new NoRequestApi();
  readonly controller: ClipboardController;
  opens: number = 0;

  constructor() {
    const deps: ClipboardDeps = new ClipboardDeps(this.board, this.api, this.pending);
    deps.consent = (): string => ClipboardReadPolicy.CONSENT_AGREED;
    deps.guest = (): boolean => true;
    deps.scope = (): string => 'hm13d-guest';
    deps.clock = (): number => 1800000000000;
    deps.open = (_route: string, _params: Record<string, Object>): boolean => {
      this.opens++;
      return true;
    };
    this.controller = new ClipboardController(deps);
    this.controller.sync();
    this.controller.onForeground();
  }

  async recognize(raw: string): Promise<ClipboardPromptView> {
    this.board.text = '邀请码 ' + raw;
    const outcome: string = await this.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
    same('recognition completed', outcome, PasteOutcome.INVITE_PROMPT);
    const prompt: ClipboardPromptView | null = this.controller.snapshot.prompt;
    expect(prompt !== null).assertTrue();
    return prompt as ClipboardPromptView;
  }

  async confirm(raw: string): Promise<void> {
    const prompt: ClipboardPromptView = await this.recognize(raw);
    const confirmed: boolean = this.controller.confirmPrompt(prompt.id);
    same('confirmation handled', confirmed, true);
    same('confirmation settled', this.controller.snapshot.prompt === null, true);
  }
}

class LinkEntry {
  readonly pending: PendingInviteCode = new PendingInviteCode();
  readonly routes: string[] = [];

  dispatch(raw: string): InviteLinkDecision {
    return InviteLinkDispatcher.dispatch(new InviteLinkInput(raw, true, true, null, false), this.pending,
      (route: string, _params: Record<string, Object>): boolean => {
        this.routes.push(route);
        return true;
      });
  }
}

export default function pendingInviteHM13dTest() {
  describe('PendingInviteHM13d', () => {
    const root: SetVectorsRoot = JSON.parse(LOGIN_VECTORS_JSON) as SetVectorsRoot;
    const vectors: PendingSetVectors = root.pendingInviteSet;

    it('vectors_manifest', 0, () => {
      same('version', vectors.version, 2);
      same('valid count', vectors.valid.length, 8);
      same('invalid count', vectors.invalid.length, 11);
      same('sequence count', vectors.sequences.length, 3);
    });

    for (let index: number = 0; index < vectors.valid.length; index++) {
      const row: ValidSetVector = vectors.valid[index];
      it('valid.' + index, 0, () => {
        const pending: PendingInviteCode = new PendingInviteCode();
        setAndCheck(pending, row.raw, true, row.stored, 'valid.' + index);
        same('shared normalization', InviteField.normalize(row.raw), row.stored);
        same('shared validator', InviteField.isValidCode(row.stored), true);
        same('consume normalized value', pending.consumeForRequest(), row.stored);
        same('consumed once', pending.peek(), null);
      });
    }

    for (let index: number = 0; index < vectors.invalid.length; index++) {
      const raw: string = vectors.invalid[index];
      it('invalid.' + index + '.empty', 0, () => {
        const pending: PendingInviteCode = new PendingInviteCode();
        setAndCheck(pending, raw, false, null, 'invalid.' + index + '.empty');
        same('shared validator rejects', InviteField.isValidCode(InviteField.normalize(raw)), false);
        same('nothing to consume', pending.consumeForRequest(), null);
      });
      it('invalid.' + index + '.retains_old', 0, () => {
        const pending: PendingInviteCode = new PendingInviteCode();
        // 前置写入的返回值也检查；与空容器场景分开，便于先红定位。
        setAndCheck(pending, OLD_CODE, true, OLD_CODE, 'seed');
        setAndCheck(pending, raw, false, OLD_CODE, 'invalid.' + index + '.retains_old');
        same('request still consumes old code', pending.consumeForRequest(), OLD_CODE);
        same('consumed once', pending.peek(), null);
      });
    }

    for (let index: number = 0; index < vectors.sequences.length; index++) {
      const row: SetSequenceVector = vectors.sequences[index];
      it('sequences.' + index, 0, () => {
        same('step count', row.steps.length, STEP_ACCEPTED[index].length);
        const pending: PendingInviteCode = new PendingInviteCode();
        for (let step: number = 0; step < row.steps.length; step++) {
          setAndCheck(pending, row.steps[step], STEP_ACCEPTED[index][step], STEP_STORED[index][step],
            'sequences.' + index + '.step.' + step);
        }
        same('vector final stored', pending.peek(), row.stored);
      });
    }

    it('shared_validator_alphabet_every_position_and_optional_blank', 0, () => {
      // 独立于生产 PATTERN 的规则真值；逐位覆盖 L 等容易被另写的正则误排除的合法字符。
      const allowed: string = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
      const candidates: string = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-!_';
      const context: Record<string, Object> = {};
      for (let position: number = 0; position < OLD_CODE.length; position++) {
        for (let index: number = 0; index < candidates.length; index++) {
          const character: string = candidates.charAt(index);
          const code: string = OLD_CODE.substring(0, position) + character + OLD_CODE.substring(position + 1);
          const valid: boolean = allowed.indexOf(character) >= 0;
          same(code + '.isValidCode', InviteField.isValidCode(code), valid);
          same(code + '.decide', InviteField.decide(code, context).valid, valid);
          const pending: PendingInviteCode = new PendingInviteCode();
          setAndCheck(pending, OLD_CODE, true, OLD_CODE, 'seed');
          setAndCheck(pending, code, valid, valid ? code : OLD_CODE, code);
        }
      }
      same('empty is not a code', InviteField.isValidCode(''), false);
      same('optional login field still allows omission', InviteField.decide('', context).valid, true);
    });

    it('all_unicode_whitespace_and_zero_width_are_removed_before_validation', 0, () => {
      const stripped: string[] = ['\u0009', '\u000a', '\u000b', '\u000c', '\u000d', '\u0020', '\u0085',
        '\u00a0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006',
        '\u2007', '\u2008', '\u2009', '\u200a', '\u2028', '\u2029', '\u202f', '\u205f', '\u3000',
        '\u200b', '\u200c', '\u200d', '\ufeff'];
      for (let index: number = 0; index < stripped.length; index++) {
        const raw: string = stripped[index] + 'k7' + stripped[index] + 'm2qx' + stripped[index];
        const pending: PendingInviteCode = new PendingInviteCode();
        setAndCheck(pending, raw, true, OLD_CODE, 'unicode.' + index);
      }
    });

    for (let existing: number = 0; existing < 2; existing++) {
      it('clipboard.invalid_text.' + existing, 0, async () => {
        const f: ClipEntry = new ClipEntry();
        if (existing === 1) {
          await f.confirm(OLD_CODE);
          same('seeded through controller', f.pending.peek(), OLD_CODE);
        }
        f.board.text = '邀请码 ' + BAD_CODE;
        const outcome: string = await f.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
        same('bad text cannot produce invite prompt', outcome === PasteOutcome.INVITE_PROMPT, false);
        const prompt: ClipboardPromptView | null = f.controller.snapshot.prompt;
        const stored: string | null = f.pending.peek();
        same('no invite prompt', prompt === null, true);
        same('bad text preserves container', stored, existing === 1 ? OLD_CODE : null);
        same('no request', f.api.calls, 0);
        // 正例对照：后续合法候选经同一入口确实被采用。
        await f.confirm(NEW_CODE);
        same('new valid content adopted', f.pending.peek(), NEW_CODE);
      });

      it('clipboard.confirm_invalid_candidate.' + existing, 0, async () => {
        const f: ClipEntry = new ClipEntry();
        if (existing === 1) {
          await f.confirm(OLD_CODE);
          same('seeded through controller', f.pending.peek(), OLD_CODE);
        }
        const prompt: ClipboardPromptView = await f.recognize(NEW_CODE);
        same('real candidate recognized', prompt.inviteCode, NEW_CODE);
        // 窄故障注入：识别器平时只产合格码。真实识别建立 ticket/id 后，替换公开 snapshot 的候选值；
        // 不伪造 ticket、不调用私有函数、不直接 set，以 confirmPrompt 验证最后一道写入边界。
        f.controller.snapshot.prompt = new ClipboardPromptView(prompt.id, prompt.kind, BAD_CODE, prompt.entry, prompt.info);
        // 不约束非法候选时 confirmPrompt 的返回值，只约束静默拒写与完成后的状态。
        f.controller.confirmPrompt(prompt.id);
        const stored: string | null = f.pending.peek();
        const afterPrompt: ClipboardPromptView | null = f.controller.snapshot.prompt;
        same('bad candidate preserves container', stored, existing === 1 ? OLD_CODE : null);
        same('confirmation dismissed', afterPrompt === null, true);
        same('no new error result', f.controller.snapshot.result === null, true);
        same('no navigation', f.opens, 0);
        same('no request', f.api.calls, 0);
        await f.confirm(NEW_CODE);
        same('valid after rejection adopted', f.pending.peek(), NEW_CODE);
      });

      it('invite_link.invalid_then_valid.' + existing, 0, () => {
        const f: LinkEntry = new LinkEntry();
        if (existing === 1) {
          same('seed decision', f.dispatch(OLD_CODE).kindRaw, InviteLinkDecision.LOGIN);
          same('seed through dispatch', f.pending.peek(), OLD_CODE);
        }
        const before: number = f.routes.length;
        const bad: InviteLinkDecision = f.dispatch(BAD_CODE);
        const stored: string | null = f.pending.peek();
        same('bad link dropped', bad.kindRaw, InviteLinkDecision.DROP);
        same('no bad code in decision', bad.code, null);
        same('old code preserved', stored, existing === 1 ? OLD_CODE : null);
        same('no extra route for invalid code', f.routes.length, before);
        const good: InviteLinkDecision = f.dispatch('t3st22');
        same('valid link handled', good.kindRaw, InviteLinkDecision.LOGIN);
        same('normalized decision', good.code, NEW_CODE);
        same('valid replacement adopted', f.pending.peek(), NEW_CODE);
        same('one route for valid code', f.routes.length, before + 1);
        same('login route', f.routes[f.routes.length - 1], 'Login');
      });
    }
  });
}
