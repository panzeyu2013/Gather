/* CSQLite placeholder translation unit.
 *
 * The CSQLite target only ships a module.modulemap + shim.h. Newer SwiftPM
 * build systems (Xcode 16+/26/27, Swift 6.4) still emit a link input for the
 * target and fail with "Build input file cannot be found: .../CSQLite.o"
 * when the target has no C source at all. This intentionally empty TU keeps
 * the target compilable without changing the SQLite shim itself.
 *
 * Do NOT add logic here; the shim lives in include/shim.h.
 */
