export interface MetadataWriteAttributes {
  keywords?: string[]
  rating?: number
  dateTaken?: string
  latitude?: number
  longitude?: number
}

export interface MetadataWriter {
  readKeywords(photoPath: string): Promise<string[]>

  writeAttributes(photoPath: string, tags: MetadataWriteAttributes): Promise<void>

  /**
   * Creates a pre-write safety backup. Called in execute() just before writeAttributes().
   * For XmpSidecarWriter: copies .xmp → .xmp.bak.
   * For EmbeddedWriter: exiftool handles atomicity internally; returns '' (no-op).
   */
  backup(photoPath: string): Promise<string>

  restore(photoPath: string, backupPath: string): Promise<void>

  /**
   * Returns the expected backup path without creating any files.
   * Used during preview() to record the backup location.
   */
  getBackupPath(photoPath: string): string

  supportsFormat(fileExtension: string): boolean
}
