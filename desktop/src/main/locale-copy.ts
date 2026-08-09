// 主进程侧文案表（唯一来源）：应用菜单、ML 后端标签、致命启动弹窗、
// 报告/导出文档模板。这些表面的共同点是渲染层无法接管（Electron 原生
// 菜单 / 渲染器不可用 / 文档内容），因此统一收敛到 `mainCopy(locale)`，
// 按 AppLocale 解析，替代原先分散在各文件里的双语表。
// 纯模块（不 import electron），可直接单测；locale 由调用方解析传入。
// UI 文案仍归渲染层 i18next 负责；这里只承载上述四类不可渲染层化的文案。

import type { AppLocale } from './locale'

export interface MenuLabels {
  appName: string
  file: string
  edit: string
  view: string
  window: string
  importFromCaptureOne: string
  about: string
  quit: string
  close: string
  undo: string
  redo: string
  cut: string
  copy: string
  paste: string
  selectAll: string
  reload: string
  toggleDevTools: string
  zoomIn: string
  zoomOut: string
  resetZoom: string
  minimize: string
  zoom: string
  front: string
}

export interface SessionSummaryTemplates {
  title: string
  totalPhotos: string
  tableHeader: string
}

export interface PersonReportTemplates {
  title: string
  bindingCount: string
  tableHeader: string
}

export interface KeywordReportTemplates {
  title: string
  faceKeywords: string
  cullingKeywords: string
  none: string
}

export interface ExportReportTemplates {
  title: string
  totalPhotos: string
  tableHeader: string
  csvHeader: string
}

export interface ReportTemplates {
  sessionSummary: SessionSummaryTemplates
  personReport: PersonReportTemplates
  keywordReport: KeywordReportTemplates
  exportReport: ExportReportTemplates
}

export interface FatalDialogCopy {
  title: string
  body: (message: string) => string
}

export interface MainCopy {
  menu: MenuLabels
  mlBackendAuto: string
  fatalDialog: FatalDialogCopy
  reports: ReportTemplates
}

const zh: MainCopy = {
  menu: {
    appName: 'Gather',
    file: '文件',
    edit: '编辑',
    view: '视图',
    window: '窗口',
    importFromCaptureOne: '从 Capture One 导入',
    about: '关于 Gather',
    quit: '退出 Gather',
    close: '关闭窗口',
    undo: '撤销',
    redo: '重做',
    cut: '剪切',
    copy: '复制',
    paste: '粘贴',
    selectAll: '全选',
    reload: '重新加载',
    toggleDevTools: '切换开发者工具',
    zoomIn: '放大',
    zoomOut: '缩小',
    resetZoom: '实际大小',
    minimize: '最小化',
    zoom: '缩放',
    front: '全部置于顶层',
  },
  mlBackendAuto: 'CoreML（失败自动回退 CPU）',
  fatalDialog: {
    title: 'Gather 无法启动',
    body: (message) => `数据库迁移或应用初始化失败。原数据库已保留，请查看日志。\n\n${message}`,
  },
  reports: {
    sessionSummary: {
      title: '# 工作区摘要',
      totalPhotos: '**照片总数：**',
      tableHeader: '| # | 文件名 | 文件路径 | 状态 |',
    },
    personReport: {
      title: '# 人物报告',
      bindingCount: '**绑定数量：**',
      tableHeader: '| 角色 | 关键词 | 人脸组 | 人脸数量 |',
    },
    keywordReport: {
      title: '# 关键词报告',
      faceKeywords: '## 人脸关键词',
      cullingKeywords: '## 筛选关键词',
      none: '*(无)*',
    },
    exportReport: {
      title: '# 工作区导出报告',
      totalPhotos: '照片总数：',
      tableHeader: '| 文件名 | 文件路径 |',
      csvHeader: '文件名,文件路径',
    },
  },
}

const en: MainCopy = {
  menu: {
    appName: 'Gather',
    file: 'File',
    edit: 'Edit',
    view: 'View',
    window: 'Window',
    importFromCaptureOne: 'Import from Capture One',
    about: 'About Gather',
    quit: 'Quit Gather',
    close: 'Close Window',
    undo: 'Undo',
    redo: 'Redo',
    cut: 'Cut',
    copy: 'Copy',
    paste: 'Paste',
    selectAll: 'Select All',
    reload: 'Reload',
    toggleDevTools: 'Toggle Developer Tools',
    zoomIn: 'Zoom In',
    zoomOut: 'Zoom Out',
    resetZoom: 'Actual Size',
    minimize: 'Minimize',
    zoom: 'Zoom',
    front: 'Bring All to Front',
  },
  mlBackendAuto: 'CoreML (falls back to CPU on failure)',
  fatalDialog: {
    title: 'Gather failed to start',
    body: (message) => `Database migration or app initialization failed. The original database was kept; see the logs.\n\n${message}`,
  },
  reports: {
    sessionSummary: {
      title: '# Workspace Summary',
      totalPhotos: '**Total photos:**',
      tableHeader: '| # | Filename | File Path | Status |',
    },
    personReport: {
      title: '# Person Report',
      bindingCount: '**Bindings:**',
      tableHeader: '| Role | Keywords | Face Group | Faces |',
    },
    keywordReport: {
      title: '# Keyword Report',
      faceKeywords: '## Face keywords',
      cullingKeywords: '## Culling keywords',
      none: '*(none)*',
    },
    exportReport: {
      title: '# Workspace Export Report',
      totalPhotos: 'Total photos:',
      tableHeader: '| Filename | File Path |',
      csvHeader: 'Filename,File Path',
    },
  },
}

export function mainCopy(locale: AppLocale): MainCopy {
  return locale === 'zh-CN' ? zh : en
}
