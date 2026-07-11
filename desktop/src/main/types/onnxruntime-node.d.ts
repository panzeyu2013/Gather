declare module 'onnxruntime-node' {
  namespace ort {
    class Tensor {
      constructor(type: string, data: Float32Array | number[] | number[][], dims?: number[])
      readonly data: Float32Array
      readonly dims: readonly number[]
    }

    interface InferenceSession {
      readonly inputNames: readonly string[]
      readonly outputNames: readonly string[]
      run(feeds: Record<string, Tensor>): Promise<Record<string, Tensor>>
      release(): Promise<void>
    }

    const InferenceSession: {
      create(modelPath: string, options?: { executionProviders?: string[] }): Promise<InferenceSession>
    }
  }
  export = ort
}
