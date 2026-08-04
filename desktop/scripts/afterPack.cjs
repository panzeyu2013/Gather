// electron-builder afterPack hook: bundle the Capture One plugin
// (GatherLink.coplugin) into the packaged app when the Capture One SDK is
// available on this machine. Without the SDK (or when the plugin build fails)
// the hook is skipped with a warning, so packaging never fails because of the
// plugin.
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

module.exports = async function afterPack(context) {
  if (context.electronPlatformName !== 'darwin') return
  const sdkPath = path.resolve(__dirname, '..', '..', 'Capture_One_Plugin_SDK_(Mac)_v1.0.1')
  const copluginDir = path.resolve(__dirname, '..', 'coplugin')
  const productName = 'GatherLink.coplugin'

  if (!fs.existsSync(sdkPath)) {
    console.warn('[afterPack] Capture One SDK not found — skipping GatherLink.coplugin build')
    return
  }

  // The plugin must match the app's architecture (an arm64-only plugin cannot
  // load inside an x64 build).
  const targetArch = context.arch === 'x64' ? 'x86_64' : 'arm64'
  const productDir = path.join(copluginDir, productName)

  try {
    // `make clean` first: make's directory-mtime heuristic can otherwise skip a
    // rebuild of a stale product copied into the tree by `make install`.
    execFileSync('make', ['clean', 'all'], {
      cwd: copluginDir,
      stdio: 'inherit',
      env: { ...process.env, TARGET_ARCH: targetArch },
    })
  } catch (error) {
    console.warn(`[afterPack] GatherLink.coplugin build failed — skipping plugin bundling`, error)
    return
  }

  // Verify the binary was produced, not just the bundle directory.
  if (!fs.existsSync(path.join(productDir, 'Contents', 'MacOS', 'GatherLink'))) {
    throw new Error('[afterPack] GatherLink.coplugin build produced no executable')
  }

  const dest = path.join(context.appOutDir, 'Contents', 'Resources', 'plugins', productName)
  fs.cpSync(productDir, dest, { recursive: true })
  console.log(`[afterPack] Bundled ${productName} -> ${dest}`)
}
