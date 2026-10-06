// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 契约枚举：contracts/enums/*.yaml。未知取值由 parseXxx 返回 undefined（不抛错），即 ArkTS 侧的 unknown。


/** 契约枚举 admin_permission */
export enum AdminPermission {
  USER_LIST = 'user.list',
  USER_LOOKUP = 'user.lookup',
  PII_REVEAL_PHONE = 'pii.reveal_phone',
  PII_REVEAL_IDENTITY = 'pii.reveal_identity',
  FUND_VIEW = 'fund.view',
  AUDIT_VIEW_ALL = 'audit.view_all',
  EXPORT = 'export',
  CONTENT_PAGE = 'content.page',
  CONTENT_POOL = 'content.pool',
  CONTENT_ARTICLE = 'content.article',
  CONTENT_AGREEMENT = 'content.agreement',
  CONTENT_POSTER = 'content.poster',
  CONTENT_APP_VERSION = 'content.app_version',
  CONTENT_FUND_TERMS = 'content.fund_terms',
  CONFIG_GENERAL = 'config.general',
  CONFIG_RISK = 'config.risk',
  CONFIG_BUSINESS = 'config.business',
  SWITCH_ALL = 'switch.all',
  SWITCH_PAYOUT = 'switch.payout',
  RISK_FREEZE = 'risk.freeze',
  RISK_BAN = 'risk.ban',
  RISK_BLOCKLIST = 'risk.blocklist',
  RISK_APPEAL = 'risk.appeal',
  UNION_BINDING_RESET = 'union.binding_reset',
  UNION_BINDING_DISABLE = 'union.binding_disable',
  UNION_ACCOUNT_AUTH = 'union.account_auth',
  UNION_PID = 'union.pid',
  USER_LEVEL = 'user.level',
  USER_INVITER = 'user.inviter',
  USER_REALNAME_FIX = 'user.realname_fix',
  USER_PHONE_CHANGE = 'user.phone_change',
  USER_DATA_EXPORT = 'user.data_export',
  ORDER_VIEW = 'order.view',
  ORDER_CLAIM = 'order.claim',
  ORDER_ASSIGN = 'order.assign',
  ORDER_HOLD = 'order.hold',
  ORDER_RESTORE = 'order.restore',
  WITHDRAW_REVIEW = 'withdraw.review',
  PAYOUT_EXECUTE = 'payout.execute',
  PAYOUT_MANUAL_ENTRY = 'payout.manual_entry',
  SETTLE_BILL = 'settle.bill',
  SETTLE_STATEMENT_UPLOAD = 'settle.statement_upload',
  FUND_ADJUST = 'fund.adjust',
  FUND_WRITEOFF = 'fund.writeoff',
  FUND_SETTLE_ADJUST = 'fund.settle_adjust',
  FUND_RECON = 'fund.recon',
  FUND_CASH_ENTRY = 'fund.cash_entry',
  AGENT_TRACE = 'agent.trace',
  AGENT_REPORT = 'agent.report'
}

export function parseAdminPermission(raw: string): AdminPermission | undefined {
  switch (raw) {
    case 'user.list':
      return AdminPermission.USER_LIST;
    case 'user.lookup':
      return AdminPermission.USER_LOOKUP;
    case 'pii.reveal_phone':
      return AdminPermission.PII_REVEAL_PHONE;
    case 'pii.reveal_identity':
      return AdminPermission.PII_REVEAL_IDENTITY;
    case 'fund.view':
      return AdminPermission.FUND_VIEW;
    case 'audit.view_all':
      return AdminPermission.AUDIT_VIEW_ALL;
    case 'export':
      return AdminPermission.EXPORT;
    case 'content.page':
      return AdminPermission.CONTENT_PAGE;
    case 'content.pool':
      return AdminPermission.CONTENT_POOL;
    case 'content.article':
      return AdminPermission.CONTENT_ARTICLE;
    case 'content.agreement':
      return AdminPermission.CONTENT_AGREEMENT;
    case 'content.poster':
      return AdminPermission.CONTENT_POSTER;
    case 'content.app_version':
      return AdminPermission.CONTENT_APP_VERSION;
    case 'content.fund_terms':
      return AdminPermission.CONTENT_FUND_TERMS;
    case 'config.general':
      return AdminPermission.CONFIG_GENERAL;
    case 'config.risk':
      return AdminPermission.CONFIG_RISK;
    case 'config.business':
      return AdminPermission.CONFIG_BUSINESS;
    case 'switch.all':
      return AdminPermission.SWITCH_ALL;
    case 'switch.payout':
      return AdminPermission.SWITCH_PAYOUT;
    case 'risk.freeze':
      return AdminPermission.RISK_FREEZE;
    case 'risk.ban':
      return AdminPermission.RISK_BAN;
    case 'risk.blocklist':
      return AdminPermission.RISK_BLOCKLIST;
    case 'risk.appeal':
      return AdminPermission.RISK_APPEAL;
    case 'union.binding_reset':
      return AdminPermission.UNION_BINDING_RESET;
    case 'union.binding_disable':
      return AdminPermission.UNION_BINDING_DISABLE;
    case 'union.account_auth':
      return AdminPermission.UNION_ACCOUNT_AUTH;
    case 'union.pid':
      return AdminPermission.UNION_PID;
    case 'user.level':
      return AdminPermission.USER_LEVEL;
    case 'user.inviter':
      return AdminPermission.USER_INVITER;
    case 'user.realname_fix':
      return AdminPermission.USER_REALNAME_FIX;
    case 'user.phone_change':
      return AdminPermission.USER_PHONE_CHANGE;
    case 'user.data_export':
      return AdminPermission.USER_DATA_EXPORT;
    case 'order.view':
      return AdminPermission.ORDER_VIEW;
    case 'order.claim':
      return AdminPermission.ORDER_CLAIM;
    case 'order.assign':
      return AdminPermission.ORDER_ASSIGN;
    case 'order.hold':
      return AdminPermission.ORDER_HOLD;
    case 'order.restore':
      return AdminPermission.ORDER_RESTORE;
    case 'withdraw.review':
      return AdminPermission.WITHDRAW_REVIEW;
    case 'payout.execute':
      return AdminPermission.PAYOUT_EXECUTE;
    case 'payout.manual_entry':
      return AdminPermission.PAYOUT_MANUAL_ENTRY;
    case 'settle.bill':
      return AdminPermission.SETTLE_BILL;
    case 'settle.statement_upload':
      return AdminPermission.SETTLE_STATEMENT_UPLOAD;
    case 'fund.adjust':
      return AdminPermission.FUND_ADJUST;
    case 'fund.writeoff':
      return AdminPermission.FUND_WRITEOFF;
    case 'fund.settle_adjust':
      return AdminPermission.FUND_SETTLE_ADJUST;
    case 'fund.recon':
      return AdminPermission.FUND_RECON;
    case 'fund.cash_entry':
      return AdminPermission.FUND_CASH_ENTRY;
    case 'agent.trace':
      return AdminPermission.AGENT_TRACE;
    case 'agent.report':
      return AdminPermission.AGENT_REPORT;
    default:
      return undefined;
  }
}

/** 契约枚举 ledger_type */
export enum LedgerType {
  REBATE_CREDIT = 'REBATE_CREDIT',
  SHARE_CREDIT = 'SHARE_CREDIT',
  REFERRAL_CREDIT = 'REFERRAL_CREDIT',
  CLAWBACK = 'CLAWBACK',
  SETTLE_ADJUST = 'SETTLE_ADJUST',
  WITHDRAW_FREEZE = 'WITHDRAW_FREEZE',
  WITHDRAW_PAID = 'WITHDRAW_PAID',
  WITHDRAW_RETURN = 'WITHDRAW_RETURN',
  WITHDRAW_FEE = 'WITHDRAW_FEE',
  TAX_WITHHOLD = 'TAX_WITHHOLD',
  REWARD = 'REWARD',
  ADMIN_ADJUST = 'ADMIN_ADJUST',
  BAD_DEBT_WRITEOFF = 'BAD_DEBT_WRITEOFF'
}

export function parseLedgerType(raw: string): LedgerType | undefined {
  switch (raw) {
    case 'REBATE_CREDIT':
      return LedgerType.REBATE_CREDIT;
    case 'SHARE_CREDIT':
      return LedgerType.SHARE_CREDIT;
    case 'REFERRAL_CREDIT':
      return LedgerType.REFERRAL_CREDIT;
    case 'CLAWBACK':
      return LedgerType.CLAWBACK;
    case 'SETTLE_ADJUST':
      return LedgerType.SETTLE_ADJUST;
    case 'WITHDRAW_FREEZE':
      return LedgerType.WITHDRAW_FREEZE;
    case 'WITHDRAW_PAID':
      return LedgerType.WITHDRAW_PAID;
    case 'WITHDRAW_RETURN':
      return LedgerType.WITHDRAW_RETURN;
    case 'WITHDRAW_FEE':
      return LedgerType.WITHDRAW_FEE;
    case 'TAX_WITHHOLD':
      return LedgerType.TAX_WITHHOLD;
    case 'REWARD':
      return LedgerType.REWARD;
    case 'ADMIN_ADJUST':
      return LedgerType.ADMIN_ADJUST;
    case 'BAD_DEBT_WRITEOFF':
      return LedgerType.BAD_DEBT_WRITEOFF;
    default:
      return undefined;
  }
}

/** 契约枚举 referral_credit_sub_type */
export enum ReferralCreditSubType {
  DIRECT = 'DIRECT',
  INDIRECT = 'INDIRECT'
}

export function parseReferralCreditSubType(raw: string): ReferralCreditSubType | undefined {
  switch (raw) {
    case 'DIRECT':
      return ReferralCreditSubType.DIRECT;
    case 'INDIRECT':
      return ReferralCreditSubType.INDIRECT;
    default:
      return undefined;
  }
}

/** 契约枚举 clawback_sub_type */
export enum ClawbackSubType {
  FULL = 'FULL',
  PART_REFUND = 'PART_REFUND',
  RIGHTS = 'RIGHTS',
  PUNISH = 'PUNISH'
}

export function parseClawbackSubType(raw: string): ClawbackSubType | undefined {
  switch (raw) {
    case 'FULL':
      return ClawbackSubType.FULL;
    case 'PART_REFUND':
      return ClawbackSubType.PART_REFUND;
    case 'RIGHTS':
      return ClawbackSubType.RIGHTS;
    case 'PUNISH':
      return ClawbackSubType.PUNISH;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_adjust_sub_type */
export enum SettleAdjustSubType {
  SETTLE_DIFF = 'SETTLE_DIFF',
  PRICE_COMPARE = 'PRICE_COMPARE',
  PRICE_PROTECT = 'PRICE_PROTECT'
}

export function parseSettleAdjustSubType(raw: string): SettleAdjustSubType | undefined {
  switch (raw) {
    case 'SETTLE_DIFF':
      return SettleAdjustSubType.SETTLE_DIFF;
    case 'PRICE_COMPARE':
      return SettleAdjustSubType.PRICE_COMPARE;
    case 'PRICE_PROTECT':
      return SettleAdjustSubType.PRICE_PROTECT;
    default:
      return undefined;
  }
}

/** 契约枚举 reward_sub_type */
export enum RewardSubType {
  NEWBIE = 'newbie',
  CHECKIN = 'checkin',
  INVITE = 'invite'
}

export function parseRewardSubType(raw: string): RewardSubType | undefined {
  switch (raw) {
    case 'newbie':
      return RewardSubType.NEWBIE;
    case 'checkin':
      return RewardSubType.CHECKIN;
    case 'invite':
      return RewardSubType.INVITE;
    default:
      return undefined;
  }
}

/** 契约枚举 admin_adjust_sub_type */
export enum AdminAdjustSubType {
  RESTORE = 'RESTORE',
  RECON_FIX = 'RECON_FIX',
  PAYOUT_RECOVERY = 'PAYOUT_RECOVERY',
  ACCOUNT_CLOSED = 'ACCOUNT_CLOSED',
  OTHER = 'OTHER'
}

export function parseAdminAdjustSubType(raw: string): AdminAdjustSubType | undefined {
  switch (raw) {
    case 'RESTORE':
      return AdminAdjustSubType.RESTORE;
    case 'RECON_FIX':
      return AdminAdjustSubType.RECON_FIX;
    case 'PAYOUT_RECOVERY':
      return AdminAdjustSubType.PAYOUT_RECOVERY;
    case 'ACCOUNT_CLOSED':
      return AdminAdjustSubType.ACCOUNT_CLOSED;
    case 'OTHER':
      return AdminAdjustSubType.OTHER;
    default:
      return undefined;
  }
}

/** 契约枚举 beneficiary_role */
export enum BeneficiaryRole {
  SELF = 'self',
  SHARE = 'share',
  DIRECT = 'direct',
  INDIRECT = 'indirect'
}

export function parseBeneficiaryRole(raw: string): BeneficiaryRole | undefined {
  switch (raw) {
    case 'self':
      return BeneficiaryRole.SELF;
    case 'share':
      return BeneficiaryRole.SHARE;
    case 'direct':
      return BeneficiaryRole.DIRECT;
    case 'indirect':
      return BeneficiaryRole.INDIRECT;
    default:
      return undefined;
  }
}

/** 契约枚举 forfeit_reason */
export enum ForfeitReason {
  BANNED = 'banned',
  DELETED = 'deleted',
  MINOR = 'minor'
}

export function parseForfeitReason(raw: string): ForfeitReason | undefined {
  switch (raw) {
    case 'banned':
      return ForfeitReason.BANNED;
    case 'deleted':
      return ForfeitReason.DELETED;
    case 'minor':
      return ForfeitReason.MINOR;
    default:
      return undefined;
  }
}

/** 契约枚举 commission_rule_status */
export enum CommissionRuleStatus {
  DRAFT = 'draft',
  PUBLISHED = 'published',
  REVOKED = 'revoked'
}

export function parseCommissionRuleStatus(raw: string): CommissionRuleStatus | undefined {
  switch (raw) {
    case 'draft':
      return CommissionRuleStatus.DRAFT;
    case 'published':
      return CommissionRuleStatus.PUBLISHED;
    case 'revoked':
      return CommissionRuleStatus.REVOKED;
    default:
      return undefined;
  }
}

/** 契约枚举 income_type */
export enum IncomeType {
  SERVICE_FEE = 'SERVICE_FEE',
  INCIDENTAL = 'INCIDENTAL'
}

export function parseIncomeType(raw: string): IncomeType | undefined {
  switch (raw) {
    case 'SERVICE_FEE':
      return IncomeType.SERVICE_FEE;
    case 'INCIDENTAL':
      return IncomeType.INCIDENTAL;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_status */
export enum WithdrawalStatus {
  PENDING_REVIEW = 'PENDING_REVIEW',
  APPROVED = 'APPROVED',
  REJECTED = 'REJECTED',
  PAYING = 'PAYING',
  PAID_API = 'PAID_API',
  PAID_MANUAL = 'PAID_MANUAL',
  FAILED = 'FAILED'
}

export function parseWithdrawalStatus(raw: string): WithdrawalStatus | undefined {
  switch (raw) {
    case 'PENDING_REVIEW':
      return WithdrawalStatus.PENDING_REVIEW;
    case 'APPROVED':
      return WithdrawalStatus.APPROVED;
    case 'REJECTED':
      return WithdrawalStatus.REJECTED;
    case 'PAYING':
      return WithdrawalStatus.PAYING;
    case 'PAID_API':
      return WithdrawalStatus.PAID_API;
    case 'PAID_MANUAL':
      return WithdrawalStatus.PAID_MANUAL;
    case 'FAILED':
      return WithdrawalStatus.FAILED;
    default:
      return undefined;
  }
}

/** 契约枚举 withdraw_reject_reason */
export enum WithdrawRejectReason {
  RISK_SUSPECT = 'RISK_SUSPECT',
  ORDER_ABNORMAL = 'ORDER_ABNORMAL',
  PAYEE_INFO_INVALID = 'PAYEE_INFO_INVALID',
  USER_REQUEST = 'USER_REQUEST',
  OTHER = 'OTHER',
  NEGATIVE_BALANCE = 'NEGATIVE_BALANCE'
}

export function parseWithdrawRejectReason(raw: string): WithdrawRejectReason | undefined {
  switch (raw) {
    case 'RISK_SUSPECT':
      return WithdrawRejectReason.RISK_SUSPECT;
    case 'ORDER_ABNORMAL':
      return WithdrawRejectReason.ORDER_ABNORMAL;
    case 'PAYEE_INFO_INVALID':
      return WithdrawRejectReason.PAYEE_INFO_INVALID;
    case 'USER_REQUEST':
      return WithdrawRejectReason.USER_REQUEST;
    case 'OTHER':
      return WithdrawRejectReason.OTHER;
    case 'NEGATIVE_BALANCE':
      return WithdrawRejectReason.NEGATIVE_BALANCE;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_hold_reason */
export enum WithdrawalHoldReason {
  PAYOUT_DISABLED = 'payout_disabled',
  QUEUE_PAUSED = 'queue_paused',
  CHANNEL_DISABLED = 'channel_disabled',
  MEMBER_BLOCKED = 'member_blocked',
  SINGLE_CAP = 'single_cap',
  DAILY_CAP = 'daily_cap',
  PAYER_SIDE_AFTER_TRANSFER = 'payer_side_after_transfer'
}

export function parseWithdrawalHoldReason(raw: string): WithdrawalHoldReason | undefined {
  switch (raw) {
    case 'payout_disabled':
      return WithdrawalHoldReason.PAYOUT_DISABLED;
    case 'queue_paused':
      return WithdrawalHoldReason.QUEUE_PAUSED;
    case 'channel_disabled':
      return WithdrawalHoldReason.CHANNEL_DISABLED;
    case 'member_blocked':
      return WithdrawalHoldReason.MEMBER_BLOCKED;
    case 'single_cap':
      return WithdrawalHoldReason.SINGLE_CAP;
    case 'daily_cap':
      return WithdrawalHoldReason.DAILY_CAP;
    case 'payer_side_after_transfer':
      return WithdrawalHoldReason.PAYER_SIDE_AFTER_TRANSFER;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_blocked_reason */
export enum WithdrawalBlockedReason {
  NEGATIVE_BALANCE = 'NEGATIVE_BALANCE'
}

export function parseWithdrawalBlockedReason(raw: string): WithdrawalBlockedReason | undefined {
  switch (raw) {
    case 'NEGATIVE_BALANCE':
      return WithdrawalBlockedReason.NEGATIVE_BALANCE;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_manual_resolution */
export enum WithdrawalManualResolution {
  PAID = 'paid',
  FAILED = 'failed'
}

export function parseWithdrawalManualResolution(raw: string): WithdrawalManualResolution | undefined {
  switch (raw) {
    case 'paid':
      return WithdrawalManualResolution.PAID;
    case 'failed':
      return WithdrawalManualResolution.FAILED;
    default:
      return undefined;
  }
}

/** 契约枚举 withdraw_hold_kind */
export enum WithdrawHoldKind {
  MANUAL = 'manual',
  RECON_DIFF = 'recon_diff',
  LEDGER_MISMATCH = 'ledger_mismatch',
  MANUAL_FAILED_WATCH = 'manual_failed_watch'
}

export function parseWithdrawHoldKind(raw: string): WithdrawHoldKind | undefined {
  switch (raw) {
    case 'manual':
      return WithdrawHoldKind.MANUAL;
    case 'recon_diff':
      return WithdrawHoldKind.RECON_DIFF;
    case 'ledger_mismatch':
      return WithdrawHoldKind.LEDGER_MISMATCH;
    case 'manual_failed_watch':
      return WithdrawHoldKind.MANUAL_FAILED_WATCH;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_review_mode */
export enum WithdrawalReviewMode {
  AUTO = 'auto',
  MANUAL = 'manual'
}

export function parseWithdrawalReviewMode(raw: string): WithdrawalReviewMode | undefined {
  switch (raw) {
    case 'auto':
      return WithdrawalReviewMode.AUTO;
    case 'manual':
      return WithdrawalReviewMode.MANUAL;
    default:
      return undefined;
  }
}

/** 契约枚举 payout_method */
export enum PayoutMethod {
  ALIPAY = 'alipay',
  BANK_CARD = 'bank_card',
  WECHAT = 'wechat'
}

export function parsePayoutMethod(raw: string): PayoutMethod | undefined {
  switch (raw) {
    case 'alipay':
      return PayoutMethod.ALIPAY;
    case 'bank_card':
      return PayoutMethod.BANK_CARD;
    case 'wechat':
      return PayoutMethod.WECHAT;
    default:
      return undefined;
  }
}

/** 契约枚举 withdrawal_channel_state */
export enum WithdrawalChannelState {
  PROCESSING = 'processing',
  WAIT_USER_CONFIRM = 'wait_user_confirm',
  CANCELING = 'canceling'
}

export function parseWithdrawalChannelState(raw: string): WithdrawalChannelState | undefined {
  switch (raw) {
    case 'processing':
      return WithdrawalChannelState.PROCESSING;
    case 'wait_user_confirm':
      return WithdrawalChannelState.WAIT_USER_CONFIRM;
    case 'canceling':
      return WithdrawalChannelState.CANCELING;
    default:
      return undefined;
  }
}

/** 契约枚举 payout_attempt_kind */
export enum PayoutAttemptKind {
  TRANSFER = 'transfer',
  QUERY = 'query',
  CANCEL = 'cancel'
}

export function parsePayoutAttemptKind(raw: string): PayoutAttemptKind | undefined {
  switch (raw) {
    case 'transfer':
      return PayoutAttemptKind.TRANSFER;
    case 'query':
      return PayoutAttemptKind.QUERY;
    case 'cancel':
      return PayoutAttemptKind.CANCEL;
    default:
      return undefined;
  }
}

/** 契约枚举 withdraw_condition_reason */
export enum WithdrawConditionReason {
  ACCOUNT_FROZEN = 'account_frozen',
  BELOW_MIN = 'below_min',
  NOT_MULTIPLE = 'not_multiple',
  ABOVE_MAX = 'above_max',
  ABOVE_METHOD_MAX = 'above_method_max',
  NET_TOO_SMALL = 'net_too_small',
  DAILY_COUNT = 'daily_count',
  MONTHLY_COUNT = 'monthly_count',
  PAYEE_DAILY_COUNT = 'payee_daily_count',
  PAYEE_DAILY_USERS = 'payee_daily_users',
  SELF_PURCHASE_REQUIRED = 'self_purchase_required',
  PAYOUT_ACCOUNT_CHANGE_LIMIT = 'payout_account_change_limit',
  PAYOUT_ACCOUNT_VERIFY_LIMIT = 'payout_account_verify_limit'
}

export function parseWithdrawConditionReason(raw: string): WithdrawConditionReason | undefined {
  switch (raw) {
    case 'account_frozen':
      return WithdrawConditionReason.ACCOUNT_FROZEN;
    case 'below_min':
      return WithdrawConditionReason.BELOW_MIN;
    case 'not_multiple':
      return WithdrawConditionReason.NOT_MULTIPLE;
    case 'above_max':
      return WithdrawConditionReason.ABOVE_MAX;
    case 'above_method_max':
      return WithdrawConditionReason.ABOVE_METHOD_MAX;
    case 'net_too_small':
      return WithdrawConditionReason.NET_TOO_SMALL;
    case 'daily_count':
      return WithdrawConditionReason.DAILY_COUNT;
    case 'monthly_count':
      return WithdrawConditionReason.MONTHLY_COUNT;
    case 'payee_daily_count':
      return WithdrawConditionReason.PAYEE_DAILY_COUNT;
    case 'payee_daily_users':
      return WithdrawConditionReason.PAYEE_DAILY_USERS;
    case 'self_purchase_required':
      return WithdrawConditionReason.SELF_PURCHASE_REQUIRED;
    case 'payout_account_change_limit':
      return WithdrawConditionReason.PAYOUT_ACCOUNT_CHANGE_LIMIT;
    case 'payout_account_verify_limit':
      return WithdrawConditionReason.PAYOUT_ACCOUNT_VERIFY_LIMIT;
    default:
      return undefined;
  }
}

/** 契约枚举 payout_batch_kind */
export enum PayoutBatchKind {
  MANUAL = 'manual',
  AUTO = 'auto'
}

export function parsePayoutBatchKind(raw: string): PayoutBatchKind | undefined {
  switch (raw) {
    case 'manual':
      return PayoutBatchKind.MANUAL;
    case 'auto':
      return PayoutBatchKind.AUTO;
    default:
      return undefined;
  }
}

/** 契约枚举 bad_debt_writeoff_status */
export enum BadDebtWriteoffStatus {
  PENDING = 'PENDING',
  APPROVED = 'APPROVED',
  CANCELLED = 'CANCELLED'
}

export function parseBadDebtWriteoffStatus(raw: string): BadDebtWriteoffStatus | undefined {
  switch (raw) {
    case 'PENDING':
      return BadDebtWriteoffStatus.PENDING;
    case 'APPROVED':
      return BadDebtWriteoffStatus.APPROVED;
    case 'CANCELLED':
      return BadDebtWriteoffStatus.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_batch_status */
export enum SettleBatchStatus {
  DRAFT = 'DRAFT',
  CONFIRMED = 'CONFIRMED',
  EXECUTING = 'EXECUTING',
  PARTIAL = 'PARTIAL',
  DONE = 'DONE',
  CANCELLED = 'CANCELLED'
}

export function parseSettleBatchStatus(raw: string): SettleBatchStatus | undefined {
  switch (raw) {
    case 'DRAFT':
      return SettleBatchStatus.DRAFT;
    case 'CONFIRMED':
      return SettleBatchStatus.CONFIRMED;
    case 'EXECUTING':
      return SettleBatchStatus.EXECUTING;
    case 'PARTIAL':
      return SettleBatchStatus.PARTIAL;
    case 'DONE':
      return SettleBatchStatus.DONE;
    case 'CANCELLED':
      return SettleBatchStatus.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_mode */
export enum SettleMode {
  IMMEDIATE = 'IMMEDIATE',
  SCHEDULED = 'SCHEDULED'
}

export function parseSettleMode(raw: string): SettleMode | undefined {
  switch (raw) {
    case 'IMMEDIATE':
      return SettleMode.IMMEDIATE;
    case 'SCHEDULED':
      return SettleMode.SCHEDULED;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_batch_item_result */
export enum SettleBatchItemResult {
  CREDITED = 'credited',
  SKIPPED = 'skipped',
  DEFERRED = 'deferred'
}

export function parseSettleBatchItemResult(raw: string): SettleBatchItemResult | undefined {
  switch (raw) {
    case 'credited':
      return SettleBatchItemResult.CREDITED;
    case 'skipped':
      return SettleBatchItemResult.SKIPPED;
    case 'deferred':
      return SettleBatchItemResult.DEFERRED;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_batch_item_type */
export enum SettleBatchItemType {
  ORDER = 'order',
  BENEFICIARY = 'beneficiary'
}

export function parseSettleBatchItemType(raw: string): SettleBatchItemType | undefined {
  switch (raw) {
    case 'order':
      return SettleBatchItemType.ORDER;
    case 'beneficiary':
      return SettleBatchItemType.BENEFICIARY;
    default:
      return undefined;
  }
}

/** 契约枚举 settle_adjustment_status */
export enum SettleAdjustmentStatus {
  PENDING = 'pending',
  APPROVED = 'approved',
  REJECTED = 'rejected',
  VOIDED_STALE_SEQ = 'voided_stale_seq',
  VOIDED_BY_CLAWBACK = 'voided_by_clawback'
}

export function parseSettleAdjustmentStatus(raw: string): SettleAdjustmentStatus | undefined {
  switch (raw) {
    case 'pending':
      return SettleAdjustmentStatus.PENDING;
    case 'approved':
      return SettleAdjustmentStatus.APPROVED;
    case 'rejected':
      return SettleAdjustmentStatus.REJECTED;
    case 'voided_stale_seq':
      return SettleAdjustmentStatus.VOIDED_STALE_SEQ;
    case 'voided_by_clawback':
      return SettleAdjustmentStatus.VOIDED_BY_CLAWBACK;
    default:
      return undefined;
  }
}

/** 契约枚举 beneficiary_credit_kind */
export enum BeneficiaryCreditKind {
  FIRST_CREDIT = 'first_credit',
  REASSIGN_CREDIT = 'reassign_credit',
  DEFERRED = 'deferred'
}

export function parseBeneficiaryCreditKind(raw: string): BeneficiaryCreditKind | undefined {
  switch (raw) {
    case 'first_credit':
      return BeneficiaryCreditKind.FIRST_CREDIT;
    case 'reassign_credit':
      return BeneficiaryCreditKind.REASSIGN_CREDIT;
    case 'deferred':
      return BeneficiaryCreditKind.DEFERRED;
    default:
      return undefined;
  }
}

/** 契约枚举 beneficiary_credit_status */
export enum BeneficiaryCreditStatus {
  OPEN = 'open',
  DONE = 'done',
  FORFEITED = 'forfeited',
  VOIDED = 'voided'
}

export function parseBeneficiaryCreditStatus(raw: string): BeneficiaryCreditStatus | undefined {
  switch (raw) {
    case 'open':
      return BeneficiaryCreditStatus.OPEN;
    case 'done':
      return BeneficiaryCreditStatus.DONE;
    case 'forfeited':
      return BeneficiaryCreditStatus.FORFEITED;
    case 'voided':
      return BeneficiaryCreditStatus.VOIDED;
    default:
      return undefined;
  }
}

/** 契约枚举 recon_diff_type */
export enum ReconDiffType {
  UNION_MISMATCH = 'union_mismatch',
  CHANNEL_MISMATCH = 'channel_mismatch',
  LEDGER_MISMATCH = 'ledger_mismatch',
  PLATFORM_RESTORE = 'platform_restore',
  MONTH_END_UNBALANCED = 'month_end_unbalanced',
  SETTLE_AMOUNT_MISMATCH = 'settle_amount_mismatch',
  SETTLE_MISSING = 'settle_missing',
  APPEAL_RESTORE = 'appeal_restore',
  ESTIMATE_CHANGED_AFTER_CREDIT = 'estimate_changed_after_credit'
}

export function parseReconDiffType(raw: string): ReconDiffType | undefined {
  switch (raw) {
    case 'union_mismatch':
      return ReconDiffType.UNION_MISMATCH;
    case 'channel_mismatch':
      return ReconDiffType.CHANNEL_MISMATCH;
    case 'ledger_mismatch':
      return ReconDiffType.LEDGER_MISMATCH;
    case 'platform_restore':
      return ReconDiffType.PLATFORM_RESTORE;
    case 'month_end_unbalanced':
      return ReconDiffType.MONTH_END_UNBALANCED;
    case 'settle_amount_mismatch':
      return ReconDiffType.SETTLE_AMOUNT_MISMATCH;
    case 'settle_missing':
      return ReconDiffType.SETTLE_MISSING;
    case 'appeal_restore':
      return ReconDiffType.APPEAL_RESTORE;
    case 'estimate_changed_after_credit':
      return ReconDiffType.ESTIMATE_CHANGED_AFTER_CREDIT;
    default:
      return undefined;
  }
}

/** 契约枚举 payout_batch_item_result */
export enum PayoutBatchItemResult {
  PAYING = 'paying',
  SKIPPED = 'skipped',
  BLOCKED = 'blocked',
  MOVED_OUT = 'moved_out'
}

export function parsePayoutBatchItemResult(raw: string): PayoutBatchItemResult | undefined {
  switch (raw) {
    case 'paying':
      return PayoutBatchItemResult.PAYING;
    case 'skipped':
      return PayoutBatchItemResult.SKIPPED;
    case 'blocked':
      return PayoutBatchItemResult.BLOCKED;
    case 'moved_out':
      return PayoutBatchItemResult.MOVED_OUT;
    default:
      return undefined;
  }
}

/** 契约枚举 recon_diff_status */
export enum ReconDiffStatus {
  OPEN = 'open',
  PROCESSING = 'processing',
  ADJUSTED = 'adjusted',
  WRITTEN_OFF = 'written_off',
  CLOSED = 'closed'
}

export function parseReconDiffStatus(raw: string): ReconDiffStatus | undefined {
  switch (raw) {
    case 'open':
      return ReconDiffStatus.OPEN;
    case 'processing':
      return ReconDiffStatus.PROCESSING;
    case 'adjusted':
      return ReconDiffStatus.ADJUSTED;
    case 'written_off':
      return ReconDiffStatus.WRITTEN_OFF;
    case 'closed':
      return ReconDiffStatus.CLOSED;
    default:
      return undefined;
  }
}

/** 契约枚举 identity_level */
export enum IdentityLevel {
  BASIC = 'basic',
  GUEST = 'guest',
  MEMBER = 'member',
  PHONE = 'phone',
  REALNAME = 'realname'
}

export function parseIdentityLevel(raw: string): IdentityLevel | undefined {
  switch (raw) {
    case 'basic':
      return IdentityLevel.BASIC;
    case 'guest':
      return IdentityLevel.GUEST;
    case 'member':
      return IdentityLevel.MEMBER;
    case 'phone':
      return IdentityLevel.PHONE;
    case 'realname':
      return IdentityLevel.REALNAME;
    default:
      return undefined;
  }
}

/** 契约枚举 login_provider */
export enum LoginProvider {
  WECHAT = 'wechat',
  APPLE = 'apple',
  HUAWEI = 'huawei'
}

export function parseLoginProvider(raw: string): LoginProvider | undefined {
  switch (raw) {
    case 'wechat':
      return LoginProvider.WECHAT;
    case 'apple':
      return LoginProvider.APPLE;
    case 'huawei':
      return LoginProvider.HUAWEI;
    default:
      return undefined;
  }
}

/** 契约枚举 device_id_source */
export enum DeviceIdSource {
  IDFV = 'idfv',
  ANDROID_ID = 'android_id',
  OAID = 'oaid',
  ODID = 'odid'
}

export function parseDeviceIdSource(raw: string): DeviceIdSource | undefined {
  switch (raw) {
    case 'idfv':
      return DeviceIdSource.IDFV;
    case 'android_id':
      return DeviceIdSource.ANDROID_ID;
    case 'oaid':
      return DeviceIdSource.OAID;
    case 'odid':
      return DeviceIdSource.ODID;
    default:
      return undefined;
  }
}

/** 契约枚举 oauth_attempt_purpose */
export enum OauthAttemptPurpose {
  LOGIN = 'login',
  STEP_UP = 'step_up',
  PAYOUT_BIND = 'payout_bind'
}

export function parseOauthAttemptPurpose(raw: string): OauthAttemptPurpose | undefined {
  switch (raw) {
    case 'login':
      return OauthAttemptPurpose.LOGIN;
    case 'step_up':
      return OauthAttemptPurpose.STEP_UP;
    case 'payout_bind':
      return OauthAttemptPurpose.PAYOUT_BIND;
    default:
      return undefined;
  }
}

/** 契约枚举 session_scope */
export enum SessionScope {
  FULL = 'full',
  DELETION_ONLY = 'deletion_only'
}

export function parseSessionScope(raw: string): SessionScope | undefined {
  switch (raw) {
    case 'full':
      return SessionScope.FULL;
    case 'deletion_only':
      return SessionScope.DELETION_ONLY;
    default:
      return undefined;
  }
}

/** 契约枚举 h5_token_scope */
export enum H5TokenScope {
  STANDARD = 'standard',
  READ_ONLY = 'read_only'
}

export function parseH5TokenScope(raw: string): H5TokenScope | undefined {
  switch (raw) {
    case 'standard':
      return H5TokenScope.STANDARD;
    case 'read_only':
      return H5TokenScope.READ_ONLY;
    default:
      return undefined;
  }
}

/** 契约枚举 sms_purpose */
export enum SmsPurpose {
  LOGIN = 'login',
  BIND = 'bind',
  STEP_UP = 'step_up'
}

export function parseSmsPurpose(raw: string): SmsPurpose | undefined {
  switch (raw) {
    case 'login':
      return SmsPurpose.LOGIN;
    case 'bind':
      return SmsPurpose.BIND;
    case 'step_up':
      return SmsPurpose.STEP_UP;
    default:
      return undefined;
  }
}

/** 契约枚举 step_up_action */
export enum StepUpAction {
  WITHDRAW = 'withdraw',
  PAYOUT_ACCOUNT_CHANGE = 'payout_account_change',
  PHONE_CHANGE = 'phone_change',
  ACCOUNT_DELETION = 'account_deletion'
}

export function parseStepUpAction(raw: string): StepUpAction | undefined {
  switch (raw) {
    case 'withdraw':
      return StepUpAction.WITHDRAW;
    case 'payout_account_change':
      return StepUpAction.PAYOUT_ACCOUNT_CHANGE;
    case 'phone_change':
      return StepUpAction.PHONE_CHANGE;
    case 'account_deletion':
      return StepUpAction.ACCOUNT_DELETION;
    default:
      return undefined;
  }
}

/** 契约枚举 idempotency_abandon_outcome */
export enum IdempotencyAbandonOutcome {
  ABANDONED = 'abandoned',
  COMPLETED = 'completed'
}

export function parseIdempotencyAbandonOutcome(raw: string): IdempotencyAbandonOutcome | undefined {
  switch (raw) {
    case 'abandoned':
      return IdempotencyAbandonOutcome.ABANDONED;
    case 'completed':
      return IdempotencyAbandonOutcome.COMPLETED;
    default:
      return undefined;
  }
}

/** 契约枚举 consent_type */
export enum ConsentType {
  PRIVACY = 'privacy',
  AGREEMENT = 'agreement',
  AI_THIRD_PARTY = 'ai_third_party',
  ID_VERIFICATION = 'id_verification',
  PERSONALIZATION = 'personalization',
  LABOR_AGREEMENT = 'labor_agreement'
}

export function parseConsentType(raw: string): ConsentType | undefined {
  switch (raw) {
    case 'privacy':
      return ConsentType.PRIVACY;
    case 'agreement':
      return ConsentType.AGREEMENT;
    case 'ai_third_party':
      return ConsentType.AI_THIRD_PARTY;
    case 'id_verification':
      return ConsentType.ID_VERIFICATION;
    case 'personalization':
      return ConsentType.PERSONALIZATION;
    case 'labor_agreement':
      return ConsentType.LABOR_AGREEMENT;
    default:
      return undefined;
  }
}

/** 契约枚举 consent_channel */
export enum ConsentChannel {
  FIRST_LAUNCH = 'first_launch',
  LOGIN_PAGE = 'login_page',
  H5_LANDING = 'h5_landing',
  AGENT_SHEET = 'agent_sheet',
  REALNAME_SHEET = 'realname_sheet',
  PRIVACY_CENTER = 'privacy_center',
  LOGIN_MERGE = 'login_merge',
  WITHDRAW_FLOW = 'withdraw_flow'
}

export function parseConsentChannel(raw: string): ConsentChannel | undefined {
  switch (raw) {
    case 'first_launch':
      return ConsentChannel.FIRST_LAUNCH;
    case 'login_page':
      return ConsentChannel.LOGIN_PAGE;
    case 'h5_landing':
      return ConsentChannel.H5_LANDING;
    case 'agent_sheet':
      return ConsentChannel.AGENT_SHEET;
    case 'realname_sheet':
      return ConsentChannel.REALNAME_SHEET;
    case 'privacy_center':
      return ConsentChannel.PRIVACY_CENTER;
    case 'login_merge':
      return ConsentChannel.LOGIN_MERGE;
    case 'withdraw_flow':
      return ConsentChannel.WITHDRAW_FLOW;
    default:
      return undefined;
  }
}

/** 契约枚举 auth_method */
export enum AuthMethod {
  WEB_CODE = 'web_code',
  SDK_TOKEN = 'sdk_token'
}

export function parseAuthMethod(raw: string): AuthMethod | undefined {
  switch (raw) {
    case 'web_code':
      return AuthMethod.WEB_CODE;
    case 'sdk_token':
      return AuthMethod.SDK_TOKEN;
    default:
      return undefined;
  }
}

/** 契约枚举 union_binding_status */
export enum UnionBindingStatus {
  UNBOUND = 'unbound',
  PENDING_AUTH = 'pending_auth',
  ACTIVE = 'active',
  INVALID = 'invalid',
  RELEASED = 'released',
  BLOCKED = 'blocked'
}

export function parseUnionBindingStatus(raw: string): UnionBindingStatus | undefined {
  switch (raw) {
    case 'unbound':
      return UnionBindingStatus.UNBOUND;
    case 'pending_auth':
      return UnionBindingStatus.PENDING_AUTH;
    case 'active':
      return UnionBindingStatus.ACTIVE;
    case 'invalid':
      return UnionBindingStatus.INVALID;
    case 'released':
      return UnionBindingStatus.RELEASED;
    case 'blocked':
      return UnionBindingStatus.BLOCKED;
    default:
      return undefined;
  }
}

/** 契约枚举 union_binding_blocked_reason */
export enum UnionBindingBlockedReason {
  BAN = 'ban',
  ADMIN_DISABLE = 'admin_disable',
  DELETION = 'deletion'
}

export function parseUnionBindingBlockedReason(raw: string): UnionBindingBlockedReason | undefined {
  switch (raw) {
    case 'ban':
      return UnionBindingBlockedReason.BAN;
    case 'admin_disable':
      return UnionBindingBlockedReason.ADMIN_DISABLE;
    case 'deletion':
      return UnionBindingBlockedReason.DELETION;
    default:
      return undefined;
  }
}

/** 契约枚举 risk_state */
export enum RiskState {
  NORMAL = 'normal',
  FROZEN = 'frozen',
  APPEALING = 'appealing',
  BANNED = 'banned'
}

export function parseRiskState(raw: string): RiskState | undefined {
  switch (raw) {
    case 'normal':
      return RiskState.NORMAL;
    case 'frozen':
      return RiskState.FROZEN;
    case 'appealing':
      return RiskState.APPEALING;
    case 'banned':
      return RiskState.BANNED;
    default:
      return undefined;
  }
}

/** 契约枚举 realname_status */
export enum RealnameStatus {
  NONE = 'none',
  VERIFIED = 'verified',
  FAILED = 'failed'
}

export function parseRealnameStatus(raw: string): RealnameStatus | undefined {
  switch (raw) {
    case 'none':
      return RealnameStatus.NONE;
    case 'verified':
      return RealnameStatus.VERIFIED;
    case 'failed':
      return RealnameStatus.FAILED;
    default:
      return undefined;
  }
}

/** 契约枚举 deletion_status */
export enum DeletionStatus {
  COOLING = 'cooling',
  PROCESSING = 'processing',
  DONE = 'done',
  CANCELLED = 'cancelled'
}

export function parseDeletionStatus(raw: string): DeletionStatus | undefined {
  switch (raw) {
    case 'cooling':
      return DeletionStatus.COOLING;
    case 'processing':
      return DeletionStatus.PROCESSING;
    case 'done':
      return DeletionStatus.DONE;
    case 'cancelled':
      return DeletionStatus.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 deletion_cancel_reason */
export enum DeletionCancelReason {
  USER = 'user',
  NEGATIVE_BALANCE = 'negative_balance'
}

export function parseDeletionCancelReason(raw: string): DeletionCancelReason | undefined {
  switch (raw) {
    case 'user':
      return DeletionCancelReason.USER;
    case 'negative_balance':
      return DeletionCancelReason.NEGATIVE_BALANCE;
    default:
      return undefined;
  }
}

/** 契约枚举 tip_key */
export enum TipKey {
  JUMP_TIP = 'jump_tip',
  INVITER_BEFORE_BUY = 'inviter_before_buy'
}

export function parseTipKey(raw: string): TipKey | undefined {
  switch (raw) {
    case 'jump_tip':
      return TipKey.JUMP_TIP;
    case 'inviter_before_buy':
      return TipKey.INVITER_BEFORE_BUY;
    default:
      return undefined;
  }
}

/** 契约枚举 appeal_status */
export enum AppealStatus {
  PROCESSING = 'processing',
  UPHELD = 'upheld',
  REVOKED = 'revoked'
}

export function parseAppealStatus(raw: string): AppealStatus | undefined {
  switch (raw) {
    case 'processing':
      return AppealStatus.PROCESSING;
    case 'upheld':
      return AppealStatus.UPHELD;
    case 'revoked':
      return AppealStatus.REVOKED;
    default:
      return undefined;
  }
}

/** 契约枚举 appeal_target_type */
export enum AppealTargetType {
  ACCOUNT = 'account',
  ORDER = 'order',
  BLOCKED_REQUEST = 'blocked_request'
}

export function parseAppealTargetType(raw: string): AppealTargetType | undefined {
  switch (raw) {
    case 'account':
      return AppealTargetType.ACCOUNT;
    case 'order':
      return AppealTargetType.ORDER;
    case 'blocked_request':
      return AppealTargetType.BLOCKED_REQUEST;
    default:
      return undefined;
  }
}

/** 契约枚举 blocked_request_type */
export enum BlockedRequestType {
  REGISTER = 'register',
  WITHDRAW = 'withdraw',
  PHONE_CHANGE = 'phone_change',
  PAYOUT_ACCOUNT = 'payout_account'
}

export function parseBlockedRequestType(raw: string): BlockedRequestType | undefined {
  switch (raw) {
    case 'register':
      return BlockedRequestType.REGISTER;
    case 'withdraw':
      return BlockedRequestType.WITHDRAW;
    case 'phone_change':
      return BlockedRequestType.PHONE_CHANGE;
    case 'payout_account':
      return BlockedRequestType.PAYOUT_ACCOUNT;
    default:
      return undefined;
  }
}

/** 契约枚举 notify_template_code */
export enum NotifyTemplateCode {
  ORDER_TRACKED = 'ORDER_TRACKED',
  ORDER_INVALID = 'ORDER_INVALID',
  CREDITED = 'CREDITED',
  CLAWBACK = 'CLAWBACK',
  WD_SUCCESS = 'WD_SUCCESS',
  WD_REJECTED = 'WD_REJECTED',
  WD_FAILED = 'WD_FAILED',
  WD_OVERDUE = 'WD_OVERDUE',
  CLAIM_RESULT = 'CLAIM_RESULT',
  RISK_STATE_CHANGED = 'RISK_STATE_CHANGED',
  APPEAL_RESULT = 'APPEAL_RESULT',
  DELETION_PROGRESS = 'DELETION_PROGRESS',
  BALANCE_ADJUSTED = 'BALANCE_ADJUSTED',
  SMS_CODE = 'SMS_CODE',
  UNION_AUTH_EXPIRING = 'UNION_AUTH_EXPIRING',
  UNION_AUTH_EXPIRED = 'UNION_AUTH_EXPIRED'
}

export function parseNotifyTemplateCode(raw: string): NotifyTemplateCode | undefined {
  switch (raw) {
    case 'ORDER_TRACKED':
      return NotifyTemplateCode.ORDER_TRACKED;
    case 'ORDER_INVALID':
      return NotifyTemplateCode.ORDER_INVALID;
    case 'CREDITED':
      return NotifyTemplateCode.CREDITED;
    case 'CLAWBACK':
      return NotifyTemplateCode.CLAWBACK;
    case 'WD_SUCCESS':
      return NotifyTemplateCode.WD_SUCCESS;
    case 'WD_REJECTED':
      return NotifyTemplateCode.WD_REJECTED;
    case 'WD_FAILED':
      return NotifyTemplateCode.WD_FAILED;
    case 'WD_OVERDUE':
      return NotifyTemplateCode.WD_OVERDUE;
    case 'CLAIM_RESULT':
      return NotifyTemplateCode.CLAIM_RESULT;
    case 'RISK_STATE_CHANGED':
      return NotifyTemplateCode.RISK_STATE_CHANGED;
    case 'APPEAL_RESULT':
      return NotifyTemplateCode.APPEAL_RESULT;
    case 'DELETION_PROGRESS':
      return NotifyTemplateCode.DELETION_PROGRESS;
    case 'BALANCE_ADJUSTED':
      return NotifyTemplateCode.BALANCE_ADJUSTED;
    case 'SMS_CODE':
      return NotifyTemplateCode.SMS_CODE;
    case 'UNION_AUTH_EXPIRING':
      return NotifyTemplateCode.UNION_AUTH_EXPIRING;
    case 'UNION_AUTH_EXPIRED':
      return NotifyTemplateCode.UNION_AUTH_EXPIRED;
    default:
      return undefined;
  }
}

/** 契约枚举 notify_category */
export enum NotifyCategory {
  SERVICE = 'service',
  SUBSCRIPTION = 'subscription',
  MARKETING = 'marketing'
}

export function parseNotifyCategory(raw: string): NotifyCategory | undefined {
  switch (raw) {
    case 'service':
      return NotifyCategory.SERVICE;
    case 'subscription':
      return NotifyCategory.SUBSCRIPTION;
    case 'marketing':
      return NotifyCategory.MARKETING;
    default:
      return undefined;
  }
}

/** 契约枚举 user_level */
export enum UserLevel {
  L1 = 'L1',
  L2 = 'L2',
  L3 = 'L3'
}

export function parseUserLevel(raw: string): UserLevel | undefined {
  switch (raw) {
    case 'L1':
      return UserLevel.L1;
    case 'L2':
      return UserLevel.L2;
    case 'L3':
      return UserLevel.L3;
    default:
      return undefined;
  }
}

/** 契约枚举 agent_intent */
export enum AgentIntent {
  FIND_BY_LINK = 'find_by_link',
  SEARCH = 'search',
  REFINE = 'refine',
  ORDER_QUERY = 'order_query',
  RULE_QA = 'rule_qa',
  HANDOFF = 'handoff',
  CLARIFY = 'clarify',
  OUT_OF_SCOPE = 'out_of_scope',
  PAGE_GUIDE = 'page_guide',
  EARNINGS_QUERY = 'earnings_query'
}

export function parseAgentIntent(raw: string): AgentIntent | undefined {
  switch (raw) {
    case 'find_by_link':
      return AgentIntent.FIND_BY_LINK;
    case 'search':
      return AgentIntent.SEARCH;
    case 'refine':
      return AgentIntent.REFINE;
    case 'order_query':
      return AgentIntent.ORDER_QUERY;
    case 'rule_qa':
      return AgentIntent.RULE_QA;
    case 'handoff':
      return AgentIntent.HANDOFF;
    case 'clarify':
      return AgentIntent.CLARIFY;
    case 'out_of_scope':
      return AgentIntent.OUT_OF_SCOPE;
    case 'page_guide':
      return AgentIntent.PAGE_GUIDE;
    case 'earnings_query':
      return AgentIntent.EARNINGS_QUERY;
    default:
      return undefined;
  }
}

/** 契约枚举 agent_card_type */
export enum AgentCardType {
  PRODUCT_LIST = 'product_list',
  REBATE_QUOTE = 'rebate_quote',
  ORDER_STATUS = 'order_status',
  CLAIM_DRAFT = 'claim_draft',
  HANDOFF = 'handoff',
  AUTH_REQUIRED = 'auth_required',
  NOTICE = 'notice',
  RULE_REF = 'rule_ref',
  PAGE_GUIDE = 'page_guide',
  EARNINGS_SUMMARY = 'earnings_summary'
}

export function parseAgentCardType(raw: string): AgentCardType | undefined {
  switch (raw) {
    case 'product_list':
      return AgentCardType.PRODUCT_LIST;
    case 'rebate_quote':
      return AgentCardType.REBATE_QUOTE;
    case 'order_status':
      return AgentCardType.ORDER_STATUS;
    case 'claim_draft':
      return AgentCardType.CLAIM_DRAFT;
    case 'handoff':
      return AgentCardType.HANDOFF;
    case 'auth_required':
      return AgentCardType.AUTH_REQUIRED;
    case 'notice':
      return AgentCardType.NOTICE;
    case 'rule_ref':
      return AgentCardType.RULE_REF;
    case 'page_guide':
      return AgentCardType.PAGE_GUIDE;
    case 'earnings_summary':
      return AgentCardType.EARNINGS_SUMMARY;
    default:
      return undefined;
  }
}

/** 契约枚举 page_guide_reject_reason */
export enum PageGuideRejectReason {
  NOT_ALLOWED = 'not_allowed',
  EXTRA_FIELDS = 'extra_fields',
  DISABLED = 'disabled',
  UNTRUSTED_INPUT = 'untrusted_input',
  PARAMS_REQUESTED = 'params_requested'
}

export function parsePageGuideRejectReason(raw: string): PageGuideRejectReason | undefined {
  switch (raw) {
    case 'not_allowed':
      return PageGuideRejectReason.NOT_ALLOWED;
    case 'extra_fields':
      return PageGuideRejectReason.EXTRA_FIELDS;
    case 'disabled':
      return PageGuideRejectReason.DISABLED;
    case 'untrusted_input':
      return PageGuideRejectReason.UNTRUSTED_INPUT;
    case 'params_requested':
      return PageGuideRejectReason.PARAMS_REQUESTED;
    default:
      return undefined;
  }
}

/** 契约枚举 agent_finish_reason */
export enum AgentFinishReason {
  STOP = 'stop',
  CANCELLED = 'cancelled',
  LIMIT = 'limit',
  BUDGET = 'budget',
  ERROR = 'error',
  AUTH_REQUIRED = 'auth_required',
  SAFETY = 'safety',
  FALLBACK = 'fallback',
  TIMEOUT = 'timeout'
}

export function parseAgentFinishReason(raw: string): AgentFinishReason | undefined {
  switch (raw) {
    case 'stop':
      return AgentFinishReason.STOP;
    case 'cancelled':
      return AgentFinishReason.CANCELLED;
    case 'limit':
      return AgentFinishReason.LIMIT;
    case 'budget':
      return AgentFinishReason.BUDGET;
    case 'error':
      return AgentFinishReason.ERROR;
    case 'auth_required':
      return AgentFinishReason.AUTH_REQUIRED;
    case 'safety':
      return AgentFinishReason.SAFETY;
    case 'fallback':
      return AgentFinishReason.FALLBACK;
    case 'timeout':
      return AgentFinishReason.TIMEOUT;
    default:
      return undefined;
  }
}

/** 契约枚举 watch_status */
export enum WatchStatus {
  ACTIVE = 'active',
  PAUSED = 'paused',
  UNAVAILABLE = 'unavailable',
  EXPIRED = 'expired',
  CANCELLED = 'cancelled'
}

export function parseWatchStatus(raw: string): WatchStatus | undefined {
  switch (raw) {
    case 'active':
      return WatchStatus.ACTIVE;
    case 'paused':
      return WatchStatus.PAUSED;
    case 'unavailable':
      return WatchStatus.UNAVAILABLE;
    case 'expired':
      return WatchStatus.EXPIRED;
    case 'cancelled':
      return WatchStatus.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 watch_event_status */
export enum WatchEventStatus {
  PENDING = 'pending',
  SUPPRESSED = 'suppressed',
  SENT = 'sent'
}

export function parseWatchEventStatus(raw: string): WatchEventStatus | undefined {
  switch (raw) {
    case 'pending':
      return WatchEventStatus.PENDING;
    case 'suppressed':
      return WatchEventStatus.SUPPRESSED;
    case 'sent':
      return WatchEventStatus.SENT;
    default:
      return undefined;
  }
}

/** 契约枚举 platform_status */
export enum PlatformStatus {
  DEPOSIT_PAID = 'DEPOSIT_PAID',
  PAID = 'PAID',
  RECEIVED = 'RECEIVED',
  SETTLED = 'SETTLED',
  INVALID = 'INVALID'
}

export function parsePlatformStatus(raw: string): PlatformStatus | undefined {
  switch (raw) {
    case 'DEPOSIT_PAID':
      return PlatformStatus.DEPOSIT_PAID;
    case 'PAID':
      return PlatformStatus.PAID;
    case 'RECEIVED':
      return PlatformStatus.RECEIVED;
    case 'SETTLED':
      return PlatformStatus.SETTLED;
    case 'INVALID':
      return PlatformStatus.INVALID;
    default:
      return undefined;
  }
}

/** 契约枚举 rebate_status */
export enum RebateStatus {
  UNATTRIBUTED = 'UNATTRIBUTED',
  ESTIMATED = 'ESTIMATED',
  WAITING = 'WAITING',
  CREDITED = 'CREDITED',
  VOID = 'VOID',
  CLAWED_BACK = 'CLAWED_BACK'
}

export function parseRebateStatus(raw: string): RebateStatus | undefined {
  switch (raw) {
    case 'UNATTRIBUTED':
      return RebateStatus.UNATTRIBUTED;
    case 'ESTIMATED':
      return RebateStatus.ESTIMATED;
    case 'WAITING':
      return RebateStatus.WAITING;
    case 'CREDITED':
      return RebateStatus.CREDITED;
    case 'VOID':
      return RebateStatus.VOID;
    case 'CLAWED_BACK':
      return RebateStatus.CLAWED_BACK;
    default:
      return undefined;
  }
}

/** 契约枚举 display_status */
export enum DisplayStatus {
  PAID = 'PAID',
  DEPOSIT_PAID = 'DEPOSIT_PAID',
  WAITING = 'WAITING',
  CREDITING = 'CREDITING',
  REVIEWING = 'REVIEWING',
  RIGHTS_PENDING = 'RIGHTS_PENDING',
  CREDITED = 'CREDITED',
  CREDITED_PART_CLAWED = 'CREDITED_PART_CLAWED',
  NO_REBATE = 'NO_REBATE',
  INVALID = 'INVALID',
  CLAWED_BACK = 'CLAWED_BACK'
}

export function parseDisplayStatus(raw: string): DisplayStatus | undefined {
  switch (raw) {
    case 'PAID':
      return DisplayStatus.PAID;
    case 'DEPOSIT_PAID':
      return DisplayStatus.DEPOSIT_PAID;
    case 'WAITING':
      return DisplayStatus.WAITING;
    case 'CREDITING':
      return DisplayStatus.CREDITING;
    case 'REVIEWING':
      return DisplayStatus.REVIEWING;
    case 'RIGHTS_PENDING':
      return DisplayStatus.RIGHTS_PENDING;
    case 'CREDITED':
      return DisplayStatus.CREDITED;
    case 'CREDITED_PART_CLAWED':
      return DisplayStatus.CREDITED_PART_CLAWED;
    case 'NO_REBATE':
      return DisplayStatus.NO_REBATE;
    case 'INVALID':
      return DisplayStatus.INVALID;
    case 'CLAWED_BACK':
      return DisplayStatus.CLAWED_BACK;
    default:
      return undefined;
  }
}

/** 契约枚举 order_hold_reason */
export enum OrderHoldReason {
  RISK = 'RISK',
  CS = 'CS',
  UNMAPPED_STATUS = 'UNMAPPED_STATUS'
}

export function parseOrderHoldReason(raw: string): OrderHoldReason | undefined {
  switch (raw) {
    case 'RISK':
      return OrderHoldReason.RISK;
    case 'CS':
      return OrderHoldReason.CS;
    case 'UNMAPPED_STATUS':
      return OrderHoldReason.UNMAPPED_STATUS;
    default:
      return undefined;
  }
}

/** 契约枚举 order_status_group */
export enum OrderStatusGroup {
  ALL = 'all',
  ESTIMATING = 'estimating',
  CREDITED = 'credited',
  NO_REBATE = 'no_rebate'
}

export function parseOrderStatusGroup(raw: string): OrderStatusGroup | undefined {
  switch (raw) {
    case 'all':
      return OrderStatusGroup.ALL;
    case 'estimating':
      return OrderStatusGroup.ESTIMATING;
    case 'credited':
      return OrderStatusGroup.CREDITED;
    case 'no_rebate':
      return OrderStatusGroup.NO_REBATE;
    default:
      return undefined;
  }
}

/** 契约枚举 order_timeline_node */
export enum OrderTimelineNode {
  DEPOSIT_PAID = 'deposit_paid',
  PAID = 'paid',
  FINAL_PAID = 'final_paid',
  RECEIVED = 'received',
  CREDIT_EXPECTED = 'credit_expected',
  CREDITED = 'credited',
  INVALID = 'invalid',
  CLAWED_BACK = 'clawed_back',
  PART_CLAWED_BACK = 'part_clawed_back'
}

export function parseOrderTimelineNode(raw: string): OrderTimelineNode | undefined {
  switch (raw) {
    case 'deposit_paid':
      return OrderTimelineNode.DEPOSIT_PAID;
    case 'paid':
      return OrderTimelineNode.PAID;
    case 'final_paid':
      return OrderTimelineNode.FINAL_PAID;
    case 'received':
      return OrderTimelineNode.RECEIVED;
    case 'credit_expected':
      return OrderTimelineNode.CREDIT_EXPECTED;
    case 'credited':
      return OrderTimelineNode.CREDITED;
    case 'invalid':
      return OrderTimelineNode.INVALID;
    case 'clawed_back':
      return OrderTimelineNode.CLAWED_BACK;
    case 'part_clawed_back':
      return OrderTimelineNode.PART_CLAWED_BACK;
    default:
      return undefined;
  }
}

/** 契约枚举 order_reason */
export enum OrderReason {
  REFUND = 'REFUND',
  RIGHTS = 'RIGHTS',
  PUNISH = 'PUNISH',
  PRESALE_UNPAID = 'PRESALE_UNPAID',
  COMMISSION_ZERO = 'COMMISSION_ZERO',
  OTHER = 'OTHER',
  BLACKLIST = 'BLACKLIST',
  PART_REFUND = 'PART_REFUND',
  PRICE_COMPARE = 'PRICE_COMPARE',
  PRICE_PROTECT = 'PRICE_PROTECT',
  SETTLE_DIFF = 'SETTLE_DIFF',
  NOT_TRACKED = 'NOT_TRACKED',
  EXPIRED_CLICK = 'EXPIRED_CLICK',
  OTHER_TLJ = 'OTHER_TLJ',
  RELATION_INVALID = 'RELATION_INVALID',
  CANCELLED = 'CANCELLED'
}

export function parseOrderReason(raw: string): OrderReason | undefined {
  switch (raw) {
    case 'REFUND':
      return OrderReason.REFUND;
    case 'RIGHTS':
      return OrderReason.RIGHTS;
    case 'PUNISH':
      return OrderReason.PUNISH;
    case 'PRESALE_UNPAID':
      return OrderReason.PRESALE_UNPAID;
    case 'COMMISSION_ZERO':
      return OrderReason.COMMISSION_ZERO;
    case 'OTHER':
      return OrderReason.OTHER;
    case 'BLACKLIST':
      return OrderReason.BLACKLIST;
    case 'PART_REFUND':
      return OrderReason.PART_REFUND;
    case 'PRICE_COMPARE':
      return OrderReason.PRICE_COMPARE;
    case 'PRICE_PROTECT':
      return OrderReason.PRICE_PROTECT;
    case 'SETTLE_DIFF':
      return OrderReason.SETTLE_DIFF;
    case 'NOT_TRACKED':
      return OrderReason.NOT_TRACKED;
    case 'EXPIRED_CLICK':
      return OrderReason.EXPIRED_CLICK;
    case 'OTHER_TLJ':
      return OrderReason.OTHER_TLJ;
    case 'RELATION_INVALID':
      return OrderReason.RELATION_INVALID;
    case 'CANCELLED':
      return OrderReason.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 diff_reason */
export enum DiffReason {
  PART_REFUND = 'PART_REFUND',
  PRICE_COMPARE = 'PRICE_COMPARE',
  PRICE_PROTECT = 'PRICE_PROTECT',
  SETTLE_DIFF = 'SETTLE_DIFF'
}

export function parseDiffReason(raw: string): DiffReason | undefined {
  switch (raw) {
    case 'PART_REFUND':
      return DiffReason.PART_REFUND;
    case 'PRICE_COMPARE':
      return DiffReason.PRICE_COMPARE;
    case 'PRICE_PROTECT':
      return DiffReason.PRICE_PROTECT;
    case 'SETTLE_DIFF':
      return DiffReason.SETTLE_DIFF;
    default:
      return undefined;
  }
}

/** 契约枚举 order_rights_status */
export enum OrderRightsStatus {
  PROCESSING = 'PROCESSING',
  WAIT_COMMISSION = 'WAIT_COMMISSION',
  SUCCEEDED = 'SUCCEEDED',
  FAILED = 'FAILED'
}

export function parseOrderRightsStatus(raw: string): OrderRightsStatus | undefined {
  switch (raw) {
    case 'PROCESSING':
      return OrderRightsStatus.PROCESSING;
    case 'WAIT_COMMISSION':
      return OrderRightsStatus.WAIT_COMMISSION;
    case 'SUCCEEDED':
      return OrderRightsStatus.SUCCEEDED;
    case 'FAILED':
      return OrderRightsStatus.FAILED;
    default:
      return undefined;
  }
}

/** 契约枚举 order_rights_type */
export enum OrderRightsType {
  RIGHTS = 'RIGHTS',
  PUNISH = 'PUNISH',
  INVALID_AFTER_SETTLE = 'INVALID_AFTER_SETTLE',
  REFUND_AFTER_SETTLE = 'REFUND_AFTER_SETTLE'
}

export function parseOrderRightsType(raw: string): OrderRightsType | undefined {
  switch (raw) {
    case 'RIGHTS':
      return OrderRightsType.RIGHTS;
    case 'PUNISH':
      return OrderRightsType.PUNISH;
    case 'INVALID_AFTER_SETTLE':
      return OrderRightsType.INVALID_AFTER_SETTLE;
    case 'REFUND_AFTER_SETTLE':
      return OrderRightsType.REFUND_AFTER_SETTLE;
    default:
      return undefined;
  }
}

/** 契约枚举 claim_status */
export enum ClaimStatus {
  SUBMITTED = 'submitted',
  AUTO_MATCHED = 'auto_matched',
  MANUAL_REVIEW = 'manual_review',
  APPROVED = 'approved',
  REJECTED = 'rejected',
  CANCELLED = 'cancelled'
}

export function parseClaimStatus(raw: string): ClaimStatus | undefined {
  switch (raw) {
    case 'submitted':
      return ClaimStatus.SUBMITTED;
    case 'auto_matched':
      return ClaimStatus.AUTO_MATCHED;
    case 'manual_review':
      return ClaimStatus.MANUAL_REVIEW;
    case 'approved':
      return ClaimStatus.APPROVED;
    case 'rejected':
      return ClaimStatus.REJECTED;
    case 'cancelled':
      return ClaimStatus.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 claim_evidence_level */
export enum ClaimEvidenceLevel {
  STRONG = 'strong',
  WEAK = 'weak',
  NONE = 'none'
}

export function parseClaimEvidenceLevel(raw: string): ClaimEvidenceLevel | undefined {
  switch (raw) {
    case 'strong':
      return ClaimEvidenceLevel.STRONG;
    case 'weak':
      return ClaimEvidenceLevel.WEAK;
    case 'none':
      return ClaimEvidenceLevel.NONE;
    default:
      return undefined;
  }
}

/** 契约枚举 claim_item_decision */
export enum ClaimItemDecision {
  APPROVED = 'approved',
  REJECTED = 'rejected',
  CANCELLED = 'cancelled'
}

export function parseClaimItemDecision(raw: string): ClaimItemDecision | undefined {
  switch (raw) {
    case 'approved':
      return ClaimItemDecision.APPROVED;
    case 'rejected':
      return ClaimItemDecision.REJECTED;
    case 'cancelled':
      return ClaimItemDecision.CANCELLED;
    default:
      return undefined;
  }
}

/** 契约枚举 claim_reject_reason */
export enum ClaimRejectReason {
  NO_EVIDENCE = 'NO_EVIDENCE',
  EXPIRED_CLICK = 'EXPIRED_CLICK',
  NOT_TRACKED = 'NOT_TRACKED',
  OTHER_TLJ = 'OTHER_TLJ',
  FRAUD = 'FRAUD',
  OTHER = 'OTHER',
  NOT_IN_POOL = 'NOT_IN_POOL',
  ORDER_INVALID = 'ORDER_INVALID'
}

export function parseClaimRejectReason(raw: string): ClaimRejectReason | undefined {
  switch (raw) {
    case 'NO_EVIDENCE':
      return ClaimRejectReason.NO_EVIDENCE;
    case 'EXPIRED_CLICK':
      return ClaimRejectReason.EXPIRED_CLICK;
    case 'NOT_TRACKED':
      return ClaimRejectReason.NOT_TRACKED;
    case 'OTHER_TLJ':
      return ClaimRejectReason.OTHER_TLJ;
    case 'FRAUD':
      return ClaimRejectReason.FRAUD;
    case 'OTHER':
      return ClaimRejectReason.OTHER;
    case 'NOT_IN_POOL':
      return ClaimRejectReason.NOT_IN_POOL;
    case 'ORDER_INVALID':
      return ClaimRejectReason.ORDER_INVALID;
    default:
      return undefined;
  }
}

/** 契约枚举 platform */
export enum Platform {
  TAOBAO = 'taobao',
  JD = 'jd',
  PDD = 'pdd',
  MEITUAN = 'meituan',
  VIP = 'vip',
  DOUYIN = 'douyin',
  ELEME = 'eleme',
  KUAISHOU = 'kuaishou',
  SUNING = 'suning'
}

export function parsePlatform(raw: string): Platform | undefined {
  switch (raw) {
    case 'taobao':
      return Platform.TAOBAO;
    case 'jd':
      return Platform.JD;
    case 'pdd':
      return Platform.PDD;
    case 'meituan':
      return Platform.MEITUAN;
    case 'vip':
      return Platform.VIP;
    case 'douyin':
      return Platform.DOUYIN;
    case 'eleme':
      return Platform.ELEME;
    case 'kuaishou':
      return Platform.KUAISHOU;
    case 'suning':
      return Platform.SUNING;
    default:
      return undefined;
  }
}

/** 契约枚举 key_stability */
export enum KeyStability {
  UNVERIFIED = 'unverified',
  STABLE_24H = 'stable_24h',
  STABLE_7D = 'stable_7d',
  UNSTABLE = 'unstable'
}

export function parseKeyStability(raw: string): KeyStability | undefined {
  switch (raw) {
    case 'unverified':
      return KeyStability.UNVERIFIED;
    case 'stable_24h':
      return KeyStability.STABLE_24H;
    case 'stable_7d':
      return KeyStability.STABLE_7D;
    case 'unstable':
      return KeyStability.UNSTABLE;
    default:
      return undefined;
  }
}

/** 契约枚举 client_platform */
export enum ClientPlatform {
  IOS = 'ios',
  ANDROID = 'android',
  HARMONY = 'harmony',
  H5 = 'h5',
  ADMIN = 'admin'
}

export function parseClientPlatform(raw: string): ClientPlatform | undefined {
  switch (raw) {
    case 'ios':
      return ClientPlatform.IOS;
    case 'android':
      return ClientPlatform.ANDROID;
    case 'harmony':
      return ClientPlatform.HARMONY;
    case 'h5':
      return ClientPlatform.H5;
    case 'admin':
      return ClientPlatform.ADMIN;
    default:
      return undefined;
  }
}

/** 契约枚举 route_entry */
export enum RouteEntry {
  IN_APP = 'in_app',
  PUSH = 'push',
  DEEPLINK = 'deeplink'
}

export function parseRouteEntry(raw: string): RouteEntry | undefined {
  switch (raw) {
    case 'in_app':
      return RouteEntry.IN_APP;
    case 'push':
      return RouteEntry.PUSH;
    case 'deeplink':
      return RouteEntry.DEEPLINK;
    default:
      return undefined;
  }
}

/** 契约枚举 platform_search_status */
export enum PlatformSearchStatus {
  ON = 'on',
  OFF = 'off'
}

export function parsePlatformSearchStatus(raw: string): PlatformSearchStatus | undefined {
  switch (raw) {
    case 'on':
      return PlatformSearchStatus.ON;
    case 'off':
      return PlatformSearchStatus.OFF;
    default:
      return undefined;
  }
}

/** 契约枚举 install_channel */
export enum InstallChannel {
  APPSTORE = 'appstore',
  OFFICIAL = 'official',
  HUAWEI = 'huawei',
  AGC = 'agc'
}

export function parseInstallChannel(raw: string): InstallChannel | undefined {
  switch (raw) {
    case 'appstore':
      return InstallChannel.APPSTORE;
    case 'official':
      return InstallChannel.OFFICIAL;
    case 'huawei':
      return InstallChannel.HUAWEI;
    case 'agc':
      return InstallChannel.AGC;
    default:
      return undefined;
  }
}

/** 契约枚举 auth_level */
export enum AuthLevel {
  NONE = 'none',
  OPTIONAL = 'optional',
  LOGIN = 'login',
  PHONE = 'phone',
  REALNAME = 'realname'
}

export function parseAuthLevel(raw: string): AuthLevel | undefined {
  switch (raw) {
    case 'none':
      return AuthLevel.NONE;
    case 'optional':
      return AuthLevel.OPTIONAL;
    case 'login':
      return AuthLevel.LOGIN;
    case 'phone':
      return AuthLevel.PHONE;
    case 'realname':
      return AuthLevel.REALNAME;
    default:
      return undefined;
  }
}

/** 契约枚举 scene */
export enum Scene {
  SEARCH = 'search',
  DETAIL = 'detail',
  HOME_CARD = 'home_card',
  FEED = 'feed',
  CLIPBOARD = 'clipboard',
  AGENT = 'agent',
  SHARE = 'share',
  H5 = 'h5',
  PUSH = 'push',
  TAOLIJIN = 'taolijin',
  WATCH_ALERT = 'watch_alert',
  SHARE_EXT = 'share_ext',
  WECHAT_BOT = 'wechat_bot',
  MCP = 'mcp'
}

export function parseScene(raw: string): Scene | undefined {
  switch (raw) {
    case 'search':
      return Scene.SEARCH;
    case 'detail':
      return Scene.DETAIL;
    case 'home_card':
      return Scene.HOME_CARD;
    case 'feed':
      return Scene.FEED;
    case 'clipboard':
      return Scene.CLIPBOARD;
    case 'agent':
      return Scene.AGENT;
    case 'share':
      return Scene.SHARE;
    case 'h5':
      return Scene.H5;
    case 'push':
      return Scene.PUSH;
    case 'taolijin':
      return Scene.TAOLIJIN;
    case 'watch_alert':
      return Scene.WATCH_ALERT;
    case 'share_ext':
      return Scene.SHARE_EXT;
    case 'wechat_bot':
      return Scene.WECHAT_BOT;
    case 'mcp':
      return Scene.MCP;
    default:
      return undefined;
  }
}

/** 契约枚举 pid_scene */
export enum PidScene {
  SELF_BUY = 'self_buy',
  AGENT = 'agent',
  SHARE = 'share',
  TAOLIJIN = 'taolijin',
  FALLBACK = 'fallback',
  QUERY = 'query'
}

export function parsePidScene(raw: string): PidScene | undefined {
  switch (raw) {
    case 'self_buy':
      return PidScene.SELF_BUY;
    case 'agent':
      return PidScene.AGENT;
    case 'share':
      return PidScene.SHARE;
    case 'taolijin':
      return PidScene.TAOLIJIN;
    case 'fallback':
      return PidScene.FALLBACK;
    case 'query':
      return PidScene.QUERY;
    default:
      return undefined;
  }
}

/** 契约枚举 buy_type */
export enum BuyType {
  SELF = 'self',
  SHARE = 'share'
}

export function parseBuyType(raw: string): BuyType | undefined {
  switch (raw) {
    case 'self':
      return BuyType.SELF;
    case 'share':
      return BuyType.SHARE;
    default:
      return undefined;
  }
}

/** 契约枚举 scene_basis */
export enum SceneBasis {
  PID = 'pid',
  PARAM = 'param',
  FALLBACK = 'fallback'
}

export function parseSceneBasis(raw: string): SceneBasis | undefined {
  switch (raw) {
    case 'pid':
      return SceneBasis.PID;
    case 'param':
      return SceneBasis.PARAM;
    case 'fallback':
      return SceneBasis.FALLBACK;
    default:
      return undefined;
  }
}

/** 契约枚举 user_basis */
export enum UserBasis {
  PARAM = 'param',
  CLAIM = 'claim',
  ADMIN = 'admin'
}

export function parseUserBasis(raw: string): UserBasis | undefined {
  switch (raw) {
    case 'param':
      return UserBasis.PARAM;
    case 'claim':
      return UserBasis.CLAIM;
    case 'admin':
      return UserBasis.ADMIN;
    default:
      return undefined;
  }
}

/** 契约枚举 link_event */
export enum LinkEvent {
  CONVERT = 'convert',
  PRECOMPUTE = 'precompute',
  REGISTER = 'register',
  OPEN = 'open'
}

export function parseLinkEvent(raw: string): LinkEvent | undefined {
  switch (raw) {
    case 'convert':
      return LinkEvent.CONVERT;
    case 'precompute':
      return LinkEvent.PRECOMPUTE;
    case 'register':
      return LinkEvent.REGISTER;
    case 'open':
      return LinkEvent.OPEN;
    default:
      return undefined;
  }
}

/** 契约枚举 installed_state */
export enum InstalledState {
  TRUE = 'true',
  FALSE = 'false',
  UNKNOWN = 'unknown'
}

export function parseInstalledState(raw: string): InstalledState | undefined {
  switch (raw) {
    case 'true':
      return InstalledState.TRUE;
    case 'false':
      return InstalledState.FALSE;
    case 'unknown':
      return InstalledState.UNKNOWN;
    default:
      return undefined;
  }
}

/** 契约枚举 no_rebate_reason */
export enum NoRebateReason {
  AUTH_DECLINED = 'auth_declined',
  AUTH_FAILED = 'auth_failed',
  RELATION_CONFLICT = 'relation_conflict',
  BINDING_BLOCKED = 'binding_blocked'
}

export function parseNoRebateReason(raw: string): NoRebateReason | undefined {
  switch (raw) {
    case 'auth_declined':
      return NoRebateReason.AUTH_DECLINED;
    case 'auth_failed':
      return NoRebateReason.AUTH_FAILED;
    case 'relation_conflict':
      return NoRebateReason.RELATION_CONFLICT;
    case 'binding_blocked':
      return NoRebateReason.BINDING_BLOCKED;
    default:
      return undefined;
  }
}

/** 契约枚举 jump_type */
export enum JumpType {
  SDK = 'sdk',
  SCHEME = 'scheme',
  UNIVERSAL_LINK = 'universal_link',
  H5 = 'h5',
  COPY_TPWD = 'copy_tpwd'
}

export function parseJumpType(raw: string): JumpType | undefined {
  switch (raw) {
    case 'sdk':
      return JumpType.SDK;
    case 'scheme':
      return JumpType.SCHEME;
    case 'universal_link':
      return JumpType.UNIVERSAL_LINK;
    case 'h5':
      return JumpType.H5;
    case 'copy_tpwd':
      return JumpType.COPY_TPWD;
    default:
      return undefined;
  }
}

/** 契约枚举 input_kind */
export enum InputKind {
  TPWD = 'tpwd',
  URL = 'url',
  TEXT = 'text'
}

export function parseInputKind(raw: string): InputKind | undefined {
  switch (raw) {
    case 'tpwd':
      return InputKind.TPWD;
    case 'url':
      return InputKind.URL;
    case 'text':
      return InputKind.TEXT;
    default:
      return undefined;
  }
}

/** 契约枚举 rebate_basis */
export enum RebateBasis {
  NORMAL = 'normal',
  PRICE_COMPARE_RISK = 'price_compare_risk',
  NO_REBATE = 'no_rebate',
  AMOUNT_UNKNOWN = 'amount_unknown',
  LOGIN_REQUIRED = 'login_required'
}

export function parseRebateBasis(raw: string): RebateBasis | undefined {
  switch (raw) {
    case 'normal':
      return RebateBasis.NORMAL;
    case 'price_compare_risk':
      return RebateBasis.PRICE_COMPARE_RISK;
    case 'no_rebate':
      return RebateBasis.NO_REBATE;
    case 'amount_unknown':
      return RebateBasis.AMOUNT_UNKNOWN;
    case 'login_required':
      return RebateBasis.LOGIN_REQUIRED;
    default:
      return undefined;
  }
}

/** 契约枚举 availability */
export enum Availability {
  OK = 'ok',
  OFF_SHELF = 'off_shelf',
  COUPON_GONE = 'coupon_gone',
  REF_EXPIRED = 'ref_expired',
  PRICE_UNAVAILABLE = 'price_unavailable',
  UNKNOWN = 'unknown'
}

export function parseAvailability(raw: string): Availability | undefined {
  switch (raw) {
    case 'ok':
      return Availability.OK;
    case 'off_shelf':
      return Availability.OFF_SHELF;
    case 'coupon_gone':
      return Availability.COUPON_GONE;
    case 'ref_expired':
      return Availability.REF_EXPIRED;
    case 'price_unavailable':
      return Availability.PRICE_UNAVAILABLE;
    case 'unknown':
      return Availability.UNKNOWN;
    default:
      return undefined;
  }
}

/** 契约枚举 match_tag */
export enum MatchTag {
  MATCHED = 'matched',
  RELAXED = 'relaxed',
  SPEC_UNCONFIRMED = 'spec_unconfirmed'
}

export function parseMatchTag(raw: string): MatchTag | undefined {
  switch (raw) {
    case 'matched':
      return MatchTag.MATCHED;
    case 'relaxed':
      return MatchTag.RELAXED;
    case 'spec_unconfirmed':
      return MatchTag.SPEC_UNCONFIRMED;
    default:
      return undefined;
  }
}

/** 契约枚举 benefit */
export enum Benefit {
  COUPON = 'coupon',
  BIG_COUPON = 'big_coupon',
  TAOLIJIN = 'taolijin',
  SUBSIDY = 'subsidy',
  HIGH_REBATE = 'high_rebate'
}

export function parseBenefit(raw: string): Benefit | undefined {
  switch (raw) {
    case 'coupon':
      return Benefit.COUPON;
    case 'big_coupon':
      return Benefit.BIG_COUPON;
    case 'taolijin':
      return Benefit.TAOLIJIN;
    case 'subsidy':
      return Benefit.SUBSIDY;
    case 'high_rebate':
      return Benefit.HIGH_REBATE;
    default:
      return undefined;
  }
}

/** 契约枚举 sort */
export enum Sort {
  RELEVANCE = 'relevance',
  SALES_DESC = 'sales_desc',
  FINAL_PRICE_ASC = 'final_price_asc',
  REBATE_DESC = 'rebate_desc'
}

export function parseSort(raw: string): Sort | undefined {
  switch (raw) {
    case 'relevance':
      return Sort.RELEVANCE;
    case 'sales_desc':
      return Sort.SALES_DESC;
    case 'final_price_asc':
      return Sort.FINAL_PRICE_ASC;
    case 'rebate_desc':
      return Sort.REBATE_DESC;
    default:
      return undefined;
  }
}

/** 契约枚举 link_pattern_category */
export enum LinkPatternCategory {
  PRODUCT = 'product',
  PROMO = 'promo',
  UNION_HOST = 'union_host'
}

export function parseLinkPatternCategory(raw: string): LinkPatternCategory | undefined {
  switch (raw) {
    case 'product':
      return LinkPatternCategory.PRODUCT;
    case 'promo':
      return LinkPatternCategory.PROMO;
    case 'union_host':
      return LinkPatternCategory.UNION_HOST;
    default:
      return undefined;
  }
}

/** 契约枚举 link_kind */
export enum LinkKind {
  SHARE = 'share',
  OTHER = 'other'
}

export function parseLinkKind(raw: string): LinkKind | undefined {
  switch (raw) {
    case 'share':
      return LinkKind.SHARE;
    case 'other':
      return LinkKind.OTHER;
    default:
      return undefined;
  }
}

/** 契约枚举 no_rebate_cause */
export enum NoRebateCause {
  PRICE_COMPARE = 'price_compare'
}

export function parseNoRebateCause(raw: string): NoRebateCause | undefined {
  switch (raw) {
    case 'price_compare':
      return NoRebateCause.PRICE_COMPARE;
    default:
      return undefined;
  }
}

/** 契约枚举 tlj_kind */
export enum TljKind {
  OURS = 'ours',
  BRAND_OPEN = 'brand_open',
  THIRD_PARTY = 'third_party',
  UNKNOWN = 'unknown'
}

export function parseTljKind(raw: string): TljKind | undefined {
  switch (raw) {
    case 'ours':
      return TljKind.OURS;
    case 'brand_open':
      return TljKind.BRAND_OPEN;
    case 'third_party':
      return TljKind.THIRD_PARTY;
    case 'unknown':
      return TljKind.UNKNOWN;
    default:
      return undefined;
  }
}

/** 全部契约枚举：蛇形原名 → 契约顺序的 raw 值。 */
export class ContractEnums {
  static readonly all: Map<string, string[]> = ContractEnums.build();

  private static build(): Map<string, string[]> {
    const all: Map<string, string[]> = new Map<string, string[]>();
    all.set('admin_permission', ['user.list', 'user.lookup', 'pii.reveal_phone', 'pii.reveal_identity', 'fund.view', 'audit.view_all', 'export', 'content.page', 'content.pool', 'content.article', 'content.agreement', 'content.poster', 'content.app_version', 'content.fund_terms', 'config.general', 'config.risk', 'config.business', 'switch.all', 'switch.payout', 'risk.freeze', 'risk.ban', 'risk.blocklist', 'risk.appeal', 'union.binding_reset', 'union.binding_disable', 'union.account_auth', 'union.pid', 'user.level', 'user.inviter', 'user.realname_fix', 'user.phone_change', 'user.data_export', 'order.view', 'order.claim', 'order.assign', 'order.hold', 'order.restore', 'withdraw.review', 'payout.execute', 'payout.manual_entry', 'settle.bill', 'settle.statement_upload', 'fund.adjust', 'fund.writeoff', 'fund.settle_adjust', 'fund.recon', 'fund.cash_entry', 'agent.trace', 'agent.report']);
    all.set('ledger_type', ['REBATE_CREDIT', 'SHARE_CREDIT', 'REFERRAL_CREDIT', 'CLAWBACK', 'SETTLE_ADJUST', 'WITHDRAW_FREEZE', 'WITHDRAW_PAID', 'WITHDRAW_RETURN', 'WITHDRAW_FEE', 'TAX_WITHHOLD', 'REWARD', 'ADMIN_ADJUST', 'BAD_DEBT_WRITEOFF']);
    all.set('referral_credit_sub_type', ['DIRECT', 'INDIRECT']);
    all.set('clawback_sub_type', ['FULL', 'PART_REFUND', 'RIGHTS', 'PUNISH']);
    all.set('settle_adjust_sub_type', ['SETTLE_DIFF', 'PRICE_COMPARE', 'PRICE_PROTECT']);
    all.set('reward_sub_type', ['newbie', 'checkin', 'invite']);
    all.set('admin_adjust_sub_type', ['RESTORE', 'RECON_FIX', 'PAYOUT_RECOVERY', 'ACCOUNT_CLOSED', 'OTHER']);
    all.set('beneficiary_role', ['self', 'share', 'direct', 'indirect']);
    all.set('forfeit_reason', ['banned', 'deleted', 'minor']);
    all.set('commission_rule_status', ['draft', 'published', 'revoked']);
    all.set('income_type', ['SERVICE_FEE', 'INCIDENTAL']);
    all.set('withdrawal_status', ['PENDING_REVIEW', 'APPROVED', 'REJECTED', 'PAYING', 'PAID_API', 'PAID_MANUAL', 'FAILED']);
    all.set('withdraw_reject_reason', ['RISK_SUSPECT', 'ORDER_ABNORMAL', 'PAYEE_INFO_INVALID', 'USER_REQUEST', 'OTHER', 'NEGATIVE_BALANCE']);
    all.set('withdrawal_hold_reason', ['payout_disabled', 'queue_paused', 'channel_disabled', 'member_blocked', 'single_cap', 'daily_cap', 'payer_side_after_transfer']);
    all.set('withdrawal_blocked_reason', ['NEGATIVE_BALANCE']);
    all.set('withdrawal_manual_resolution', ['paid', 'failed']);
    all.set('withdraw_hold_kind', ['manual', 'recon_diff', 'ledger_mismatch', 'manual_failed_watch']);
    all.set('withdrawal_review_mode', ['auto', 'manual']);
    all.set('payout_method', ['alipay', 'bank_card', 'wechat']);
    all.set('withdrawal_channel_state', ['processing', 'wait_user_confirm', 'canceling']);
    all.set('payout_attempt_kind', ['transfer', 'query', 'cancel']);
    all.set('withdraw_condition_reason', ['account_frozen', 'below_min', 'not_multiple', 'above_max', 'above_method_max', 'net_too_small', 'daily_count', 'monthly_count', 'payee_daily_count', 'payee_daily_users', 'self_purchase_required', 'payout_account_change_limit', 'payout_account_verify_limit']);
    all.set('payout_batch_kind', ['manual', 'auto']);
    all.set('bad_debt_writeoff_status', ['PENDING', 'APPROVED', 'CANCELLED']);
    all.set('settle_batch_status', ['DRAFT', 'CONFIRMED', 'EXECUTING', 'PARTIAL', 'DONE', 'CANCELLED']);
    all.set('settle_mode', ['IMMEDIATE', 'SCHEDULED']);
    all.set('settle_batch_item_result', ['credited', 'skipped', 'deferred']);
    all.set('settle_batch_item_type', ['order', 'beneficiary']);
    all.set('settle_adjustment_status', ['pending', 'approved', 'rejected', 'voided_stale_seq', 'voided_by_clawback']);
    all.set('beneficiary_credit_kind', ['first_credit', 'reassign_credit', 'deferred']);
    all.set('beneficiary_credit_status', ['open', 'done', 'forfeited', 'voided']);
    all.set('recon_diff_type', ['union_mismatch', 'channel_mismatch', 'ledger_mismatch', 'platform_restore', 'month_end_unbalanced', 'settle_amount_mismatch', 'settle_missing', 'appeal_restore', 'estimate_changed_after_credit']);
    all.set('payout_batch_item_result', ['paying', 'skipped', 'blocked', 'moved_out']);
    all.set('recon_diff_status', ['open', 'processing', 'adjusted', 'written_off', 'closed']);
    all.set('identity_level', ['basic', 'guest', 'member', 'phone', 'realname']);
    all.set('login_provider', ['wechat', 'apple', 'huawei']);
    all.set('device_id_source', ['idfv', 'android_id', 'oaid', 'odid']);
    all.set('oauth_attempt_purpose', ['login', 'step_up', 'payout_bind']);
    all.set('session_scope', ['full', 'deletion_only']);
    all.set('h5_token_scope', ['standard', 'read_only']);
    all.set('sms_purpose', ['login', 'bind', 'step_up']);
    all.set('step_up_action', ['withdraw', 'payout_account_change', 'phone_change', 'account_deletion']);
    all.set('idempotency_abandon_outcome', ['abandoned', 'completed']);
    all.set('consent_type', ['privacy', 'agreement', 'ai_third_party', 'id_verification', 'personalization', 'labor_agreement']);
    all.set('consent_channel', ['first_launch', 'login_page', 'h5_landing', 'agent_sheet', 'realname_sheet', 'privacy_center', 'login_merge', 'withdraw_flow']);
    all.set('auth_method', ['web_code', 'sdk_token']);
    all.set('union_binding_status', ['unbound', 'pending_auth', 'active', 'invalid', 'released', 'blocked']);
    all.set('union_binding_blocked_reason', ['ban', 'admin_disable', 'deletion']);
    all.set('risk_state', ['normal', 'frozen', 'appealing', 'banned']);
    all.set('realname_status', ['none', 'verified', 'failed']);
    all.set('deletion_status', ['cooling', 'processing', 'done', 'cancelled']);
    all.set('deletion_cancel_reason', ['user', 'negative_balance']);
    all.set('tip_key', ['jump_tip', 'inviter_before_buy']);
    all.set('appeal_status', ['processing', 'upheld', 'revoked']);
    all.set('appeal_target_type', ['account', 'order', 'blocked_request']);
    all.set('blocked_request_type', ['register', 'withdraw', 'phone_change', 'payout_account']);
    all.set('notify_template_code', ['ORDER_TRACKED', 'ORDER_INVALID', 'CREDITED', 'CLAWBACK', 'WD_SUCCESS', 'WD_REJECTED', 'WD_FAILED', 'WD_OVERDUE', 'CLAIM_RESULT', 'RISK_STATE_CHANGED', 'APPEAL_RESULT', 'DELETION_PROGRESS', 'BALANCE_ADJUSTED', 'SMS_CODE', 'UNION_AUTH_EXPIRING', 'UNION_AUTH_EXPIRED']);
    all.set('notify_category', ['service', 'subscription', 'marketing']);
    all.set('user_level', ['L1', 'L2', 'L3']);
    all.set('agent_intent', ['find_by_link', 'search', 'refine', 'order_query', 'rule_qa', 'handoff', 'clarify', 'out_of_scope', 'page_guide', 'earnings_query']);
    all.set('agent_card_type', ['product_list', 'rebate_quote', 'order_status', 'claim_draft', 'handoff', 'auth_required', 'notice', 'rule_ref', 'page_guide', 'earnings_summary']);
    all.set('page_guide_reject_reason', ['not_allowed', 'extra_fields', 'disabled', 'untrusted_input', 'params_requested']);
    all.set('agent_finish_reason', ['stop', 'cancelled', 'limit', 'budget', 'error', 'auth_required', 'safety', 'fallback', 'timeout']);
    all.set('watch_status', ['active', 'paused', 'unavailable', 'expired', 'cancelled']);
    all.set('watch_event_status', ['pending', 'suppressed', 'sent']);
    all.set('platform_status', ['DEPOSIT_PAID', 'PAID', 'RECEIVED', 'SETTLED', 'INVALID']);
    all.set('rebate_status', ['UNATTRIBUTED', 'ESTIMATED', 'WAITING', 'CREDITED', 'VOID', 'CLAWED_BACK']);
    all.set('display_status', ['PAID', 'DEPOSIT_PAID', 'WAITING', 'CREDITING', 'REVIEWING', 'RIGHTS_PENDING', 'CREDITED', 'CREDITED_PART_CLAWED', 'NO_REBATE', 'INVALID', 'CLAWED_BACK']);
    all.set('order_hold_reason', ['RISK', 'CS', 'UNMAPPED_STATUS']);
    all.set('order_status_group', ['all', 'estimating', 'credited', 'no_rebate']);
    all.set('order_timeline_node', ['deposit_paid', 'paid', 'final_paid', 'received', 'credit_expected', 'credited', 'invalid', 'clawed_back', 'part_clawed_back']);
    all.set('order_reason', ['REFUND', 'RIGHTS', 'PUNISH', 'PRESALE_UNPAID', 'COMMISSION_ZERO', 'OTHER', 'BLACKLIST', 'PART_REFUND', 'PRICE_COMPARE', 'PRICE_PROTECT', 'SETTLE_DIFF', 'NOT_TRACKED', 'EXPIRED_CLICK', 'OTHER_TLJ', 'RELATION_INVALID', 'CANCELLED']);
    all.set('diff_reason', ['PART_REFUND', 'PRICE_COMPARE', 'PRICE_PROTECT', 'SETTLE_DIFF']);
    all.set('order_rights_status', ['PROCESSING', 'WAIT_COMMISSION', 'SUCCEEDED', 'FAILED']);
    all.set('order_rights_type', ['RIGHTS', 'PUNISH', 'INVALID_AFTER_SETTLE', 'REFUND_AFTER_SETTLE']);
    all.set('claim_status', ['submitted', 'auto_matched', 'manual_review', 'approved', 'rejected', 'cancelled']);
    all.set('claim_evidence_level', ['strong', 'weak', 'none']);
    all.set('claim_item_decision', ['approved', 'rejected', 'cancelled']);
    all.set('claim_reject_reason', ['NO_EVIDENCE', 'EXPIRED_CLICK', 'NOT_TRACKED', 'OTHER_TLJ', 'FRAUD', 'OTHER', 'NOT_IN_POOL', 'ORDER_INVALID']);
    all.set('platform', ['taobao', 'jd', 'pdd', 'meituan', 'vip', 'douyin', 'eleme', 'kuaishou', 'suning']);
    all.set('key_stability', ['unverified', 'stable_24h', 'stable_7d', 'unstable']);
    all.set('client_platform', ['ios', 'android', 'harmony', 'h5', 'admin']);
    all.set('route_entry', ['in_app', 'push', 'deeplink']);
    all.set('platform_search_status', ['on', 'off']);
    all.set('install_channel', ['appstore', 'official', 'huawei', 'agc']);
    all.set('auth_level', ['none', 'optional', 'login', 'phone', 'realname']);
    all.set('scene', ['search', 'detail', 'home_card', 'feed', 'clipboard', 'agent', 'share', 'h5', 'push', 'taolijin', 'watch_alert', 'share_ext', 'wechat_bot', 'mcp']);
    all.set('pid_scene', ['self_buy', 'agent', 'share', 'taolijin', 'fallback', 'query']);
    all.set('buy_type', ['self', 'share']);
    all.set('scene_basis', ['pid', 'param', 'fallback']);
    all.set('user_basis', ['param', 'claim', 'admin']);
    all.set('link_event', ['convert', 'precompute', 'register', 'open']);
    all.set('installed_state', ['true', 'false', 'unknown']);
    all.set('no_rebate_reason', ['auth_declined', 'auth_failed', 'relation_conflict', 'binding_blocked']);
    all.set('jump_type', ['sdk', 'scheme', 'universal_link', 'h5', 'copy_tpwd']);
    all.set('input_kind', ['tpwd', 'url', 'text']);
    all.set('rebate_basis', ['normal', 'price_compare_risk', 'no_rebate', 'amount_unknown', 'login_required']);
    all.set('availability', ['ok', 'off_shelf', 'coupon_gone', 'ref_expired', 'price_unavailable', 'unknown']);
    all.set('match_tag', ['matched', 'relaxed', 'spec_unconfirmed']);
    all.set('benefit', ['coupon', 'big_coupon', 'taolijin', 'subsidy', 'high_rebate']);
    all.set('sort', ['relevance', 'sales_desc', 'final_price_asc', 'rebate_desc']);
    all.set('link_pattern_category', ['product', 'promo', 'union_host']);
    all.set('link_kind', ['share', 'other']);
    all.set('no_rebate_cause', ['price_compare']);
    all.set('tlj_kind', ['ours', 'brand_open', 'third_party', 'unknown']);
    return all;
  }
}
