// HM-L2-STATE 参照件（节选）：CatalogManifest 里与空态 / 错误态有关的部分，形状同产品文件。
export const KIND_L1: string = 'L1 系统控件';
export const KIND_L2: string = 'L2 业务组件';
const GROUP_FEEDBACK: string = '反馈';

export class CatalogMatrix {
  variants: string[];
  states: string[];

  constructor(variants: string[], states: string[]) {
    this.variants = variants;
    this.states = states;
  }
}

export class CatalogComponent {
  name: string;
  group: string;
  kind: string;
  note: string;
  matrices: CatalogMatrix[];

  constructor(name: string, group: string, kind: string, note: string, matrices: CatalogMatrix[]) {
    this.name = name;
    this.group = group;
    this.kind = kind;
    this.note = note;
    this.matrices = matrices;
  }
}

function c(name: string, group: string, kind: string, note: string, matrices: CatalogMatrix[]): CatalogComponent {
  return new CatalogComponent(name, group, kind, note, matrices);
}

function m(variants: string[], states: string[]): CatalogMatrix {
  return new CatalogMatrix(variants, states);
}

// 注释里写 ExceptionPrompt、保留 L2 不算：说明以 c() 第 4 个实参为准。
export const COMPONENTS: CatalogComponent[] = [
  c('EmptyState', GROUP_FEEDBACK, KIND_L2, '组件库自绘空态（系统 ExceptionPrompt 是页顶提示条，整页空态无系统等价件，保留 L2）；'
    + '文案来自调用方。', [m(['empty'], ['default'])]),
  c('ErrorState', GROUP_FEEDBACK, KIND_L2, '组件库自绘错态：带 trace6 / 无网络 / 重试中（转圈防连点）；系统 ExceptionPrompt 是页顶提示条，'
    + '整页错误态无系统等价件，保留 L2；文案来自调用方。', [m(['trace6', 'offline'], ['default']), m(['trace6'], ['retrying'])]),
];
