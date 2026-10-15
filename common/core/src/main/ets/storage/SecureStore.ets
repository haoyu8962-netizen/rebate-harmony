import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/** 安全存储里的一项。 */
export class SecureEntry {
  readonly alias: string;
  readonly value: string;

  constructor(alias: string, value: string) {
    this.alias = alias;
    this.value = value;
  }
}

/**
 * 安全存储里这一项**存在**、但存的值类型或编码不对（FU-HM-0718 第 1 项，对应 Android FU-AND-0715 R1-01）：不是「没有」。
 * 调用方按「内容损坏」处理——令牌项按损坏会话隔离并删除，撤销标记按「任何会话」阻断；绝不能当成不存在而放行旧会话。
 */
export class SecureValueCorruptError extends Error {
  readonly alias: string;

  constructor(alias: string) {
    super('secure store value is not text: ' + alias);
    this.name = 'SecureValueCorruptError';
    this.alias = alias;
  }
}

/**
 * 系统密钥库保护的键值存储（03 §3.3「敏感数据走 Asset」）：令牌、未决请求体等。一个实例是一个命名空间，
 * entries / clear 只涉及本命名空间。同步接口；出错抛异常（调用方决定失败语义，清理器据此报告失败）。
 * 分组（harmony-review-r2 R2-07）：setGrouped 写入的项带一个分组标签，entriesInGroup 在存储查询层只取该组的项
 * （Asset 按标签查询），不先读出整个命名空间的秘密值再筛选。未决请求体按账号分组。
 */
export interface SecureStore {
  /**
   * 不存在为 null（只有明确查不到才是 null）；存在但值不是文本（类型 / 编码损坏）抛 SecureValueCorruptError；其他读取失败照抛。
   */
  get(alias: string): string | null;

  set(alias: string, value: string): void;

  /** 写入并打上分组标签（按账号隔离的数据用）。 */
  setGrouped(group: string, alias: string, value: string): void;

  remove(alias: string): void;

  entries(): SecureEntry[];

  /** 只取该分组的项（查询条件在存储层，别的分组的秘密值不读出）。 */
  entriesInGroup(group: string): SecureEntry[];

  clear(): void;
}

/** 内存实现（单测与 Local Test 用：Local Test 里系统 Asset 接口是空实现）。 */
export class MemorySecureStore implements SecureStore {
  private readonly values: Map<string, string> = new Map<string, string>();
  private readonly groups: Map<string, string> = new Map<string, string>();

  get(alias: string): string | null {
    const value: string | undefined = this.values.get(alias);
    return value === undefined ? null : value;
  }

  set(alias: string, value: string): void {
    this.values.set(alias, value);
    this.groups.delete(alias);
  }

  setGrouped(group: string, alias: string, value: string): void {
    this.values.set(alias, value);
    this.groups.set(alias, group);
  }

  remove(alias: string): void {
    this.values.delete(alias);
    this.groups.delete(alias);
  }

  entriesInGroup(group: string): SecureEntry[] {
    const out: SecureEntry[] = [];
    for (const alias of Array.from(this.values.keys())) {
      if (this.groups.get(alias) === group) {
        out.push(new SecureEntry(alias, this.values.get(alias) as string));
      }
    }
    return out;
  }

  entries(): SecureEntry[] {
    const out: SecureEntry[] = [];
    for (const alias of Array.from(this.values.keys())) {
      out.push(new SecureEntry(alias, this.values.get(alias) as string));
    }
    return out;
  }

  clear(): void {
    this.values.clear();
    this.groups.clear();
  }
}

/**
 * Asset Store Kit 实现（只用 API 11 / 12 的同步接口：addSync、querySync、removeSync，均不高于 API 20）。
 * - 别名 = 命名空间 + ':' + alias；DATA_LABEL_NORMAL_1 记命名空间，entries / clear 按它查询。
 * - 分组：DATA_LABEL_NORMAL_2 记分组（如账号），entriesInGroup 以命名空间 + 分组为查询条件，系统只返回该组的项（R2-07）。
 * - 首次解锁后可读（DEVICE_FIRST_UNLOCKED）；不持久到卸载之后（IS_PERSISTENT 缺省 false）；不跨设备同步（SYNC_TYPE 缺省 NEVER）。
 * - 查不到（NOT_FOUND）按空处理；查到但值不是字节抛 SecureValueCorruptError（FU-HM-0718）；其他错误抛出。
 */
export class AssetSecureStore implements SecureStore {
  private readonly namespace: string;

  constructor(namespace: string) {
    this.namespace = namespace;
  }

  get(alias: string): string | null {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, AssetSecureStore.bytes(this.fullAlias(alias)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const found: asset.AssetMap[] = this.query(query);
    return AssetSecureStore.firstSecret(found.map((item: asset.AssetMap): asset.Value | undefined =>
    item.get(asset.Tag.SECRET)), alias);
  }

  /** 查询结果（各项的 SECRET）→ 值：没有查到为 null；查到了就按 secretText 解析（类型损坏抛出，不回成 null）。 */
  static firstSecret(secrets: (asset.Value | undefined)[], alias: string): string | null {
    if (secrets.length === 0) {
      return null;
    }
    return AssetSecureStore.secretText(secrets[0], alias);
  }

  /**
   * 查到的那一项的值（FU-HM-0718 第 1 项）：SECRET 不是字节（缺失、布尔、数字）= 存在但类型损坏，抛 SecureValueCorruptError，
   * 不回落成 null（以前回落成 null，撤销标记损坏时会被当成「没有标记」放行旧会话）。
   */
  static secretText(secret: asset.Value | undefined, alias: string): string {
    if (!(secret instanceof Uint8Array)) {
      throw new SecureValueCorruptError(alias);
    }
    return AssetSecureStore.text(secret as Uint8Array);
  }

  set(alias: string, value: string): void {
    asset.addSync(this.attributes(alias, value, null));
  }

  setGrouped(group: string, alias: string, value: string): void {
    asset.addSync(this.attributes(alias, value, group));
  }

  entriesInGroup(group: string): SecureEntry[] {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, AssetSecureStore.bytes(this.namespace));
    query.set(asset.Tag.DATA_LABEL_NORMAL_2, AssetSecureStore.bytes(group));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    return this.collect(query);
  }

  private attributes(alias: string, value: string, group: string | null): asset.AssetMap {
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, AssetSecureStore.bytes(this.fullAlias(alias)));
    attributes.set(asset.Tag.SECRET, AssetSecureStore.bytes(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, AssetSecureStore.bytes(this.namespace));
    if (group !== null) {
      attributes.set(asset.Tag.DATA_LABEL_NORMAL_2, AssetSecureStore.bytes(group));
    }
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    return attributes;
  }

  remove(alias: string): void {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, AssetSecureStore.bytes(this.fullAlias(alias)));
    this.removeQuiet(query);
  }

  entries(): SecureEntry[] {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, AssetSecureStore.bytes(this.namespace));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    return this.collect(query);
  }

  private collect(query: asset.AssetMap): SecureEntry[] {
    const out: SecureEntry[] = [];
    const prefix: string = this.namespace + ':';
    for (const item of this.query(query)) {
      const aliasValue: asset.Value | undefined = item.get(asset.Tag.ALIAS);
      const secret: asset.Value | undefined = item.get(asset.Tag.SECRET);
      if (aliasValue instanceof Uint8Array && secret instanceof Uint8Array) {
        const fullAlias: string = AssetSecureStore.text(aliasValue as Uint8Array);
        if (fullAlias.startsWith(prefix)) {
          out.push(new SecureEntry(fullAlias.substring(prefix.length), AssetSecureStore.text(secret as Uint8Array)));
        }
      }
    }
    return out;
  }

  clear(): void {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, AssetSecureStore.bytes(this.namespace));
    this.removeQuiet(query);
  }

  private fullAlias(alias: string): string {
    return this.namespace + ':' + alias;
  }

  private query(query: asset.AssetMap): asset.AssetMap[] {
    try {
      return asset.querySync(query);
    } catch (e) {
      if ((e as BusinessError).code === asset.ErrorCode.NOT_FOUND) {
        return [];
      }
      throw e as Error;
    }
  }

  private removeQuiet(query: asset.AssetMap): void {
    try {
      asset.removeSync(query);
    } catch (e) {
      if ((e as BusinessError).code !== asset.ErrorCode.NOT_FOUND) {
        throw e as Error;
      }
    }
  }

  private static bytes(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  private static text(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }
}
