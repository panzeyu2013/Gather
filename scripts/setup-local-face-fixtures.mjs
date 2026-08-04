// Symlink the ONNX face models and prepare the RAW directory used by the
// git-ignored Face KW e2e fixtures (tests/fixtures/local/).
//
// Usage:
//   node scripts/setup-local-face-fixtures.mjs
//
// Environment:
//   GATHER_MODELS_DIR - directory that contains face_detector.onnx /
//                       face_encoder.onnx (default: the app's model dir,
//                       i.e. ~/Library/Application Support/Gather/models)
import { existsSync, lstatSync, mkdirSync, readdirSync, symlinkSync, unlinkSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const root = path.resolve(import.meta.dirname, '..')
const localDir = path.join(root, 'tests', 'fixtures', 'local')
const modelsDir = path.join(localDir, 'models')
const rawDir = path.join(localDir, 'raw')

const defaultModelsDir = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'Gather',
  'models',
)
const sourceModelsDir = process.env.GATHER_MODELS_DIR
  ? path.resolve(process.env.GATHER_MODELS_DIR)
  : defaultModelsDir

const MODEL_FILES = ['face_detector.onnx', 'face_encoder.onnx']

function fail(message) {
  console.error(`\n✗ ${message}\n`)
  process.exit(1)
}

mkdirSync(modelsDir, { recursive: true })
mkdirSync(rawDir, { recursive: true })

let linked = 0
for (const name of MODEL_FILES) {
  const source = path.join(sourceModelsDir, name)
  const target = path.join(modelsDir, name)
  if (!existsSync(source)) {
    console.warn(`  ! ${name} not found in ${sourceModelsDir}, skipping`)
    continue
  }
  if (existsSync(target)) {
    if (lstatSync(target).isSymbolicLink()) {
      console.log(`  = ${name} already symlinked`)
      continue
    }
    console.warn(`  ! ${target} exists but is not a symlink, leaving it`)
    continue
  }
  try {
    symlinkSync(source, target)
    linked++
    console.log(`  + symlinked ${name}`)
  } catch (error) {
    console.warn(`  ! failed to symlink ${name}: ${error.message}`)
  }
}

const rawFiles = readdirSync(rawDir).filter(
  name => /\.(arw|cr2|cr3|dng|nef|orf|raf|rw2)$/i.test(name),
)

console.log(`\nModels source: ${sourceModelsDir}`)
console.log(`Local fixtures: ${localDir}`)
if (linked === 0 && MODEL_FILES.some(name => !existsSync(path.join(modelsDir, name)))) {
  fail(
    'No models were linked. Download them first via the app ' +
    '(Workbench → face model download) or run the app once, or point ' +
    'GATHER_MODELS_DIR at a directory that contains face_detector.onnx and face_encoder.onnx.',
  )
}
if (rawFiles.length === 0) {
  console.log('  • Drop 2+ RAW photos that contain human faces into tests/fixtures/local/raw/')
} else {
  console.log(`  • ${rawFiles.length} RAW photo(s) already present in raw/`)
}
console.log('Then run: npm run test:e2e\n')
