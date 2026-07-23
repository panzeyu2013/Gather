import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { WritebackService } from '../services/writeback/writeback.service'

export function registerWritebackHandlers(registry: CommandRegistry, writebackService: WritebackService): void {
}
