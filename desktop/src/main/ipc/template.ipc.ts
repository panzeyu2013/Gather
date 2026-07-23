import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { WorkflowTemplateConfig } from '@gather/shared'
import type { TemplateService } from '../services/template/template.service'

export function registerTemplateHandlers(registry: CommandRegistry, templateService: TemplateService): void {
  registry.register(
    'template.create',
    wrapHandler(async (params) => {
      const name = validateString(params.name, 'name')
      const description = typeof params.description === 'string' ? params.description : ''
      if (!params.config || typeof params.config !== 'object') {
        throw new Error('Invalid config: must be an object')
      }
      const template = templateService.create(name, description, params.config as WorkflowTemplateConfig)
      return ok(template)
    }),
  )

  registry.register(
    'template.list',
    wrapHandler(async () => {
      return ok(templateService.list())
    }),
  )

  registry.register(
    'template.get',
    wrapHandler(async (params) => {
      const templateId = validateString(params.templateId, 'templateId')
      const template = templateService.get(templateId)
      if (!template) return err('Template not found')
      return ok(template)
    }),
  )

  registry.register(
    'template.update',
    wrapHandler(async (params) => {
      const templateId = validateString(params.templateId, 'templateId')
      const fields: Partial<{ name: string; description: string; config: WorkflowTemplateConfig }> = {}
      if (params.name !== undefined) fields.name = validateString(params.name, 'name')
      if (params.description !== undefined) fields.description = String(params.description)
      if (params.config !== undefined) {
        if (typeof params.config !== 'object') throw new Error('Invalid config: must be an object')
        fields.config = params.config as WorkflowTemplateConfig
      }
      return ok(templateService.update(templateId, fields))
    }),
  )

  registry.register(
    'template.delete',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) throw new Error('template.delete requires confirmation')
      const templateId = validateString(params.templateId, 'templateId')
      templateService.delete(templateId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'template.apply',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) throw new Error('template.apply requires confirmation')
      const templateId = validateString(params.templateId, 'templateId')
      const sessionId = validateString(params.sessionId, 'sessionId')
      templateService.apply(templateId, sessionId)
      return ok({ done: true })
    }),
  )
}
