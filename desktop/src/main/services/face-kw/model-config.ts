export const MODEL_CONFIG = {
  // ── Face Detection (SCRFD) ──
  detect: {
    inputSize: 640,
    strides: [8, 16, 32] as number[],
    anchorScales: [1.0, 2.0] as number[],
  },

  // ── Face Encoding (ArcFace) ──
  encode: {
    inputSize: 112,
    embeddingDim: 512,
  },

  // ── Default model download ──
  download: {
    packageUrl: 'https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip',
    fileMap: {
      'det_10g.onnx': 'face_detector.onnx',
      'w600k_r50.onnx': 'face_encoder.onnx',
    } as Record<string, string>,
  },
}
