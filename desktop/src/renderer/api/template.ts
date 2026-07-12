import { sendCommand } from './client'
import type { TemplateData, WorkflowTemplateConfig } from '@gather/shared'

export const templateApi = {
  list: () => sendCommand<TemplateData[]>('template.list', {}),

  get: (templateId: string) => sendCommand<TemplateData>('template.get', { templateId }),

  create: (name: string, description: string, config: WorkflowTemplateConfig) =>
    sendCommand<TemplateData>('template.create', { name, description, config }),

  update: (
    templateId: string,
    fields: Partial<{ name: string; description: string; config: WorkflowTemplateConfig }>,
  ) => sendCommand<TemplateData>('template.update', { templateId, ...fields }),

  delete: (templateId: string) =>
    sendCommand<{ done: boolean }>('template.delete', { templateId, confirmed: true }),

  apply: (templateId: string, sessionId: string) =>
    sendCommand<{ done: boolean }>('template.apply', { templateId, sessionId, confirmed: true }),
}
