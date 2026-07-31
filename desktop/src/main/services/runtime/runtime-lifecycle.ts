export interface RuntimeLifecycle {
  database?: { close(): void }
  jobs?: { stop(): Promise<void> }
  metadataSync?: { shutdown(): Promise<void> }
  writerRouter?: { shutdown(): Promise<void> }
  indexer?: { stopWatchers(): void }
}

export async function shutdownRuntime(
  runtime: RuntimeLifecycle,
  timeoutMs = 5_000,
): Promise<void> {
  runtime.indexer?.stopWatchers()
  const tasks = [
    runtime.jobs?.stop(),
    runtime.metadataSync?.shutdown(),
    runtime.writerRouter?.shutdown(),
  ].filter((task): task is Promise<void> => Boolean(task))

  try {
    await Promise.race([
      Promise.all(tasks).then(() => undefined),
      new Promise<void>((resolve) => setTimeout(resolve, timeoutMs)),
    ])
  } finally {
    runtime.database?.close()
  }
}
