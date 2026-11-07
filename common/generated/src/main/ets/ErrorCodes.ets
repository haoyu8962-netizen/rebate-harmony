// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 错误码表：contracts/error-codes.yaml（含废弃与 P1 码）。

export enum RetryKind {
  NEVER = 'never',
  AFTER_ACTION = 'after_action',
  LATER = 'later',
  IMMEDIATE = 'immediate',
  NOT_APPLICABLE = 'not_applicable'
}

export class ErrorCodeInfo {
  readonly code: number;
  readonly http: number;
  readonly retryKind: RetryKind;
  readonly retryKindByReason: Map<string, RetryKind>;
  readonly isDeprecated: boolean;
  readonly isP1: boolean;

  constructor(code: number, http: number, retryKind: RetryKind, retryKindByReason: Map<string, RetryKind>,
    isDeprecated: boolean, isP1: boolean) {
    this.code = code;
    this.http = http;
    this.retryKind = retryKind;
    this.retryKindByReason = retryKindByReason;
    this.isDeprecated = isDeprecated;
    this.isP1 = isP1;
  }
}

function reasons(keys: string[], kinds: RetryKind[]): Map<string, RetryKind> {
  const map: Map<string, RetryKind> = new Map<string, RetryKind>();
  for (let i: number = 0; i < keys.length; i++) {
    map.set(keys[i], kinds[i]);
  }
  return map;
}

export class ErrorCodes {
  static readonly all: Map<number, ErrorCodeInfo> = ErrorCodes.build();

  static info(code: number): ErrorCodeInfo | undefined {
    return ErrorCodes.all.get(code);
  }

  private static build(): Map<number, ErrorCodeInfo> {
    const all: Map<number, ErrorCodeInfo> = new Map<number, ErrorCodeInfo>();
    all.set(10001, new ErrorCodeInfo(10001, 401, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10002, new ErrorCodeInfo(10002, 401, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10003, new ErrorCodeInfo(10003, 403, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10004, new ErrorCodeInfo(10004, 403, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10005, new ErrorCodeInfo(10005, 403, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10006, new ErrorCodeInfo(10006, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(10007, new ErrorCodeInfo(10007, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(10008, new ErrorCodeInfo(10008, 401, RetryKind.NEVER, reasons([], []), false, false));
    all.set(10009, new ErrorCodeInfo(10009, 403, RetryKind.LATER, reasons([], []), false, false));
    all.set(10010, new ErrorCodeInfo(10010, 403, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10401, new ErrorCodeInfo(10401, 401, RetryKind.NEVER, reasons([], []), false, false));
    all.set(10402, new ErrorCodeInfo(10402, 401, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(10403, new ErrorCodeInfo(10403, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(10404, new ErrorCodeInfo(10404, 401, RetryKind.NOT_APPLICABLE, reasons([], []), false, false));
    all.set(10405, new ErrorCodeInfo(10405, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20001, new ErrorCodeInfo(20001, 400, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20002, new ErrorCodeInfo(20002, 400, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20003, new ErrorCodeInfo(20003, 400, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20004, new ErrorCodeInfo(20004, 400, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(20005, new ErrorCodeInfo(20005, 400, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20901, new ErrorCodeInfo(20901, 409, RetryKind.NEVER, reasons([], []), false, false));
    all.set(20902, new ErrorCodeInfo(20902, 409, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(20903, new ErrorCodeInfo(20903, 409, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30101, new ErrorCodeInfo(30101, 422, RetryKind.AFTER_ACTION, reasons(['auth_unavailable'], [RetryKind.LATER]), false, false));
    all.set(30102, new ErrorCodeInfo(30102, 422, RetryKind.AFTER_ACTION, reasons(['auth_unavailable', 'sharer_auth_invalid'], [RetryKind.LATER, RetryKind.NEVER]), false, false));
    all.set(30103, new ErrorCodeInfo(30103, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30104, new ErrorCodeInfo(30104, 422, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(30111, new ErrorCodeInfo(30111, 422, RetryKind.AFTER_ACTION, reasons(['sharer_auth_invalid'], [RetryKind.NEVER]), false, false));
    all.set(30121, new ErrorCodeInfo(30121, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30131, new ErrorCodeInfo(30131, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30132, new ErrorCodeInfo(30132, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30141, new ErrorCodeInfo(30141, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30142, new ErrorCodeInfo(30142, 422, RetryKind.NOT_APPLICABLE, reasons([], []), true, false));
    all.set(30143, new ErrorCodeInfo(30143, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30144, new ErrorCodeInfo(30144, 404, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(30145, new ErrorCodeInfo(30145, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30146, new ErrorCodeInfo(30146, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30151, new ErrorCodeInfo(30151, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30152, new ErrorCodeInfo(30152, 422, RetryKind.NOT_APPLICABLE, reasons([], []), true, false));
    all.set(30153, new ErrorCodeInfo(30153, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30154, new ErrorCodeInfo(30154, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30155, new ErrorCodeInfo(30155, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30156, new ErrorCodeInfo(30156, 422, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(30201, new ErrorCodeInfo(30201, 404, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30202, new ErrorCodeInfo(30202, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30203, new ErrorCodeInfo(30203, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30204, new ErrorCodeInfo(30204, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30205, new ErrorCodeInfo(30205, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30206, new ErrorCodeInfo(30206, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30301, new ErrorCodeInfo(30301, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30302, new ErrorCodeInfo(30302, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30303, new ErrorCodeInfo(30303, 422, RetryKind.NEVER, reasons(['payout_account_verify_limit'], [RetryKind.LATER]), false, false));
    all.set(30304, new ErrorCodeInfo(30304, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30305, new ErrorCodeInfo(30305, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30306, new ErrorCodeInfo(30306, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30307, new ErrorCodeInfo(30307, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30308, new ErrorCodeInfo(30308, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30309, new ErrorCodeInfo(30309, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30401, new ErrorCodeInfo(30401, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30402, new ErrorCodeInfo(30402, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30403, new ErrorCodeInfo(30403, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30404, new ErrorCodeInfo(30404, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30405, new ErrorCodeInfo(30405, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30406, new ErrorCodeInfo(30406, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30407, new ErrorCodeInfo(30407, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30408, new ErrorCodeInfo(30408, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30409, new ErrorCodeInfo(30409, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30410, new ErrorCodeInfo(30410, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30411, new ErrorCodeInfo(30411, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30412, new ErrorCodeInfo(30412, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30413, new ErrorCodeInfo(30413, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30414, new ErrorCodeInfo(30414, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30415, new ErrorCodeInfo(30415, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30416, new ErrorCodeInfo(30416, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30417, new ErrorCodeInfo(30417, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30418, new ErrorCodeInfo(30418, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30419, new ErrorCodeInfo(30419, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30501, new ErrorCodeInfo(30501, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30502, new ErrorCodeInfo(30502, 422, RetryKind.LATER, reasons([], []), false, false));
    all.set(30503, new ErrorCodeInfo(30503, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30504, new ErrorCodeInfo(30504, 422, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(30505, new ErrorCodeInfo(30505, 404, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30506, new ErrorCodeInfo(30506, 409, RetryKind.LATER, reasons([], []), false, false));
    all.set(30601, new ErrorCodeInfo(30601, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30602, new ErrorCodeInfo(30602, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30603, new ErrorCodeInfo(30603, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30604, new ErrorCodeInfo(30604, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30701, new ErrorCodeInfo(30701, 404, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30801, new ErrorCodeInfo(30801, 422, RetryKind.NEVER, reasons([], []), false, true));
    all.set(30802, new ErrorCodeInfo(30802, 422, RetryKind.AFTER_ACTION, reasons([], []), false, true));
    all.set(30803, new ErrorCodeInfo(30803, 409, RetryKind.NEVER, reasons([], []), false, true));
    all.set(30804, new ErrorCodeInfo(30804, 409, RetryKind.NEVER, reasons([], []), false, true));
    all.set(30805, new ErrorCodeInfo(30805, 422, RetryKind.LATER, reasons([], []), false, true));
    all.set(30806, new ErrorCodeInfo(30806, 422, RetryKind.NEVER, reasons([], []), false, true));
    all.set(30901, new ErrorCodeInfo(30901, 422, RetryKind.NEVER, reasons([], []), false, false));
    all.set(30902, new ErrorCodeInfo(30902, 409, RetryKind.NEVER, reasons([], []), false, false));
    all.set(40901, new ErrorCodeInfo(40901, 409, RetryKind.LATER, reasons([], []), false, false));
    all.set(42901, new ErrorCodeInfo(42901, 429, RetryKind.LATER, reasons([], []), false, false));
    all.set(44001, new ErrorCodeInfo(44001, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(44002, new ErrorCodeInfo(44002, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(44003, new ErrorCodeInfo(44003, 403, RetryKind.AFTER_ACTION, reasons([], []), false, false));
    all.set(44004, new ErrorCodeInfo(44004, 403, RetryKind.NEVER, reasons([], []), false, false));
    all.set(50001, new ErrorCodeInfo(50001, 500, RetryKind.IMMEDIATE, reasons([], []), false, false));
    all.set(50301, new ErrorCodeInfo(50301, 503, RetryKind.LATER, reasons(['maintenance', 'not_launched'], [RetryKind.LATER, RetryKind.NEVER]), false, false));
    all.set(50302, new ErrorCodeInfo(50302, 503, RetryKind.LATER, reasons([], []), false, false));
    all.set(50303, new ErrorCodeInfo(50303, 503, RetryKind.LATER, reasons([], []), false, false));
    all.set(50304, new ErrorCodeInfo(50304, 503, RetryKind.LATER, reasons(['search_disabled', 'rank_unavailable'], [RetryKind.NEVER, RetryKind.NEVER]), false, false));
    all.set(50305, new ErrorCodeInfo(50305, 503, RetryKind.LATER, reasons([], []), false, false));
    all.set(50306, new ErrorCodeInfo(50306, 503, RetryKind.LATER, reasons([], []), false, false));
    all.set(50401, new ErrorCodeInfo(50401, 504, RetryKind.IMMEDIATE, reasons([], []), false, false));
    return all;
  }
}
