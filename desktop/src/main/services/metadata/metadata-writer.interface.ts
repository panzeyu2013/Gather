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
   */
  backup(photoPath: string): Promise<string>

  restore(photoPath: string, backupPath: string): Promise<void>

  /**
   * Returns the expected backup path without creating any files.
   * Used during preview() to record the backup location.
   */
  getBackupPath(photoPath: string): string

  supportsFormat(fileExtension: string): boolean

  /** Release any resources (e.g. child processes) held by this writer. */
  shutdown(): Promise<void>
}
