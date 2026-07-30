import { parentPort } from 'worker_threads'
import { clusterByHash, type HashEntry, type HashGroupingMode } from '../services/similarity/cluster-engine'
import { clusterEmbeddings, type EmbeddingEntry } from '../services/face-kw/face-clusterer'

type WorkerRequest =
  | { id: number; kind: 'hash'; entries: HashEntry[]; threshold: number; minGroupSize: number; mode?: HashGroupingMode }
  | { id: number; kind: 'face'; entries: EmbeddingEntry[]; eps: number; minPts: number }

if (!parentPort) {
  throw new Error('analysis-worker must run inside a worker thread')
}

parentPort.on('message', (request: WorkerRequest) => {
  try {
    const result = request.kind === 'hash'
      ? clusterByHash(request.entries, request.threshold, request.minGroupSize, request.mode)
      : clusterEmbeddings(request.entries, request.eps, request.minPts)
    parentPort!.postMessage({ id: request.id, result })
  } catch (error) {
    parentPort!.postMessage({
      id: request.id,
      error: error instanceof Error ? error.message : String(error),
    })
  }
})
