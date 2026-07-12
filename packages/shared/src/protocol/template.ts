// packages/shared/src/protocol/template.ts

export interface TemplateCreateParams { name: string; description?: string; config: WorkflowTemplateConfig }
export interface TemplateListParams { }
export interface TemplateGetParams { templateId: string }
export interface TemplateUpdateParams { templateId: string; name?: string; description?: string; config?: WorkflowTemplateConfig }
export interface TemplateDeleteParams { templateId: string; confirmed: boolean }
export interface TemplateApplyParams { templateId: string; sessionId: string; confirmed: boolean }

export interface WorkflowTemplateConfig {
  similarity: { threshold: number; minGroupSize: number }
  face: { eps: number; minSamples: number; detectorConfidence: number }
  faceLibrary: { enabled: boolean; matchThreshold: number }
  duplicate: { enabled: boolean; visualThreshold: number }
  writeback: { createAlbums: boolean; addPrefix: boolean; markUngrouped: boolean; writeIPTC: boolean }
}

export interface TemplateData {
  id: string
  name: string
  description: string
  config: WorkflowTemplateConfig
  createdAt: string
  updatedAt: string
}
