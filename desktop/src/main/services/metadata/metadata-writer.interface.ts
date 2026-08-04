export interface MetadataWriteAttributes {
  keywords?: string[]
  rating?: number
  label?: string
  dateTaken?: string
  latitude?: number
  longitude?: number
}

/**
 * Read-only access to photo metadata. Used both for the embedded XMP inside
 * deliverable formats and for sidecar files.
 */
export interface MetadataReader {
  readKeywords(photoPath: string): Promise<string[]>

  readAttributes(photoPath: string): Promise<MetadataWriteAttributes>

  supportsFormat(fileExtension: string): boolean
}

/**
 * Durable metadata writer. All persistence paths write XMP sidecars so source
 * images stay untouched; the backup/restore machinery is owned by the writer.
 */
export interface MetadataWriter extends MetadataReader {
  writeAttributes(photoPath: string, tags: MetadataWriteAttributes): Promise<void>

  /**
   * Creates a pre-write safety backup. Called in execute() just before writeAttributes().
   */
  backup(photoPath: string): Promise<string>

  restore(photoPath: string, backupPath: string): Promise<void>

  /**
   * Returns the expected backup path without creating any files.
   * Used during preview() to record the backup location.
   */
  getBackupPath(photoPath: string): string

  /** Release any resources (e.g. child processes) held by this writer. */
  shutdown(): Promise<void>
}
