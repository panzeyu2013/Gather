declare module 'exifr' {
  export function parse(filePath: string): Promise<Record<string, unknown> | null>
}
