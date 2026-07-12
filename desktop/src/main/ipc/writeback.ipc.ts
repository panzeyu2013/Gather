import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import { WritebackService } from '../services/writeback/writeback.service'
import { getServices } from '../bootstrap'


export function registerWritebackHandlers(registry: CommandRegistry): void {
  const { writebackService } = getServices()
}
