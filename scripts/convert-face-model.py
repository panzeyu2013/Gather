#!/usr/bin/env python3
"""Build Gather's offline SFace model and verify ONNX → CoreML numeric parity.

Run on macOS with Python 3.12 and scripts/face-model-requirements.txt in a venv.
The app does not require Python, ONNX Runtime, OpenCV, or a network connection.
"""
import argparse
import hashlib
import json
import pathlib
import urllib.request

COMMIT = "47534e27c9851bb1128ccc0102f1145e27f23f98"
SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"
BASE = f"https://raw.githubusercontent.com/opencv/opencv_zoo/{COMMIT}/models/face_recognition_sface"
WEIGHTS = f"https://media.githubusercontent.com/media/opencv/opencv_zoo/{COMMIT}/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--onnx", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path(
        "desktop/native/gather-core/Sources/GatherCore/Resources/FaceModels"))
    args = parser.parse_args()
    import coremltools as ct
    import numpy as np
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert
    from PIL import Image

    args.output.mkdir(parents=True, exist_ok=True)
    source = args.onnx.read_bytes() if args.onnx else urllib.request.urlopen(WEIGHTS, timeout=120).read()
    if hashlib.sha256(source).hexdigest() != SHA256:
        raise RuntimeError("SFace weights do not match the pinned upstream SHA-256")
    graph = onnx.load_from_string(source)
    # Older ONNX exports expose initializer weights as graph inputs. They are constants.
    initializers = {value.name for value in graph.graph.initializer}
    inputs = [value for value in graph.graph.input if value.name not in initializers]
    del graph.graph.input[:]
    graph.graph.input.extend(inputs)
    torch.set_num_threads(2)
    network = convert(graph).eval()
    example = torch.zeros(1, 3, 112, 112)
    traced = torch.jit.trace(network, example)
    # SFace already contains (RGB - 127.5) / 128 preprocessing in its graph.
    model = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                       compute_precision=ct.precision.FLOAT32,
                       inputs=[ct.ImageType(name="face", shape=example.shape,
                                            color_layout=ct.colorlayout.RGB)],
                       outputs=[ct.TensorType(name="embedding")])
    model.author = "OpenCV Zoo / SFace contributors; CoreML conversion by Gather"
    model.license = "Apache-2.0"
    model.short_description = "SFace identity embedding; aligned RGB 112x112; 128 dimensions"
    model.user_defined_metadata.update({
        "gather.model": "sface", "gather.version": "2021dec-coreml-v1",
        "gather.source_sha256": SHA256, "gather.source_commit": COMMIT,
        "gather.preprocessing": "RGB uint8; graph normalization; arcface-5point-112-v1",
    })
    session = ort.InferenceSession(graph.SerializeToString(), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(20261003)
    errors = []
    for pixels in [np.zeros((112, 112, 3), np.uint8),
                   rng.integers(0, 256, (112, 112, 3), dtype=np.uint8),
                   np.arange(112 * 112 * 3).reshape(112, 112, 3).astype(np.uint8)]:
        tensor = pixels.transpose(2, 0, 1)[None].astype(np.float32)
        reference = session.run(None, {inputs[0].name: tensor})[0].reshape(-1)
        actual = np.asarray(model.predict({"face": Image.fromarray(pixels)})["embedding"]).reshape(-1)
        cosine = float(np.dot(reference, actual) / (np.linalg.norm(reference) * np.linalg.norm(actual)))
        error = float(np.max(np.abs(reference - actual)))
        if not np.isfinite(cosine) or cosine < 0.9999 or error > 0.01:
            raise RuntimeError(f"Conversion parity failed: cosine={cosine}, max_abs={error}")
        errors.append({"cosine": cosine, "max_abs": error})
    # Independent reference for the Swift VNCoreMLRequest wrapper (RGBA ramp, alpha ignored).
    rgba = np.arange(112 * 112 * 4).reshape(112, 112, 4).astype(np.uint8)
    reference = session.run(None, {inputs[0].name: rgba[:, :, :3].transpose(2, 0, 1)[None].astype(np.float32)})[0].reshape(-1)
    reference /= np.linalg.norm(reference)
    (args.output / "native_ramp_reference.json").write_text(json.dumps(reference.tolist()) + "\n")
    model.save(str(args.output / "SFace.mlpackage"))
    license_text = urllib.request.urlopen(f"{BASE}/LICENSE", timeout=30).read()
    (args.output / "LICENSE.txt").write_bytes(license_text)
    manifest = {"model": "SFace", "version": "2021dec-coreml-v1", "dimension": 128,
                "license": "Apache-2.0", "source": WEIGHTS, "source_commit": COMMIT,
                "source_sha256": SHA256, "input": "aligned RGB uint8 112x112",
                "precision": "float32", "runtime": "CoreML MLProgram",
                "conversion_parity": errors}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
