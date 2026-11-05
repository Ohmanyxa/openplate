"""Export pinned Open Model Zoo weights for the iPhone's ONNX Runtime.

Run with uv --no-project --python 3.12 --with openvino2onnx==1.1.0
--with onnx==1.18.0 --with 'protobuf<5' --with openvino --with onnxruntime
python scripts/prepare_vehicle_models.py
Source files are verified against upstream SHA-384 manifests before conversion.
"""

import hashlib
import os
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://storage.openvinotoolkit.org/repositories/open_model_zoo/"
ATTR_PATH = "2023.0/models_bin/1/vehicle-attributes-recognition-barrier-0039/FP32/"
FILES = {
    "detector.xml": (
        "2023.0/models_bin/1/vehicle-detection-0200/FP32/vehicle-detection-0200.xml",
        "acc8b78af711c51aed491261b73b133e1f389621830b233981b472a2cd876149403e02166851dc90f3a4a8eedf88f11e",
    ),
    "detector.bin": (
        "2023.0/models_bin/1/vehicle-detection-0200/FP32/vehicle-detection-0200.bin",
        "f03356341ee3142f7f2b9b7b73f2167e10a981d9081b3da5c116332ebefee0f36558eab02d26a422197505d969be489b",
    ),
    "attributes.xml": (
        f"{ATTR_PATH}vehicle-attributes-recognition-barrier-0039.xml",
        "9cafca52c680cb9f0eee61dee93465e73862e7625729da5657c09ac89b12b8a4718abc894a7a111b05931bc7999ab20c",
    ),
    "attributes.bin": (
        f"{ATTR_PATH}vehicle-attributes-recognition-barrier-0039.bin",
        "b3b6fcdfdf5d42913f5461ea35f90e886c4cb18441ae3438562a962b59d64795427a6401cd2321c6047917f7d5bf6e97",
    ),
    "reid.onnx": (
        "public/2022.1/vehicle-reid-0001/osnet_ain_x1_0_vehicle_reid.onnx",
        "0515ce72f653c39780d5b87dfed7255d396dd2b1e8b6e91fbaacdfad1da189166343157273c02f3b0fede3050ef7abb7",
    ),
}


def main():
    # Avoid an upstream ONNX/protobuf native parser deadlock on Apple Silicon.
    os.environ.setdefault("PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION", "python")
    import numpy as np
    import onnx
    import onnxruntime as ort
    import openvino as ov
    import openvino2onnx
    from openvino.passes import ConstantFolding, Manager

    destination = ROOT / "apps/openplate_mobile/assets/models/vehicle"
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="openplate-vehicles-") as temporary:
        sources = Path(temporary)
        for name, (url, expected) in FILES.items():
            with urllib.request.urlopen(BASE + url, timeout=90) as response:
                data = response.read(32 * 1024 * 1024)
            if hashlib.sha384(data).hexdigest() != expected:
                raise ValueError(f"Upstream checksum mismatch: {name}")
            (sources / name).write_bytes(data)
        for name in ("detector", "attributes"):
            model = ov.Core().read_model(sources / f"{name}.xml")
            passes = Manager()
            passes.register_pass(ConstantFolding())
            passes.run_passes(model)
            ov.serialize(model, sources / f"{name}-folded.xml")
            graph = openvino2onnx.convert_graph(sources / f"{name}-folded.xml", target_opset=17)
            exported = graph.model
            if name == "detector":
                # ONNX has no OpenVINO DetectionOutput operator. Keep the three
                # standard SSD heads and perform CENTER_SIZE decode/NMS in Swift.
                output = next(
                    node for node in exported.graph.node if node.op_type == "DetectionOutput"
                )
                heads = list(output.input)
                exported.graph.node.remove(output)
                del exported.graph.output[:]
                for input_name, output_name, shape in zip(
                    heads,
                    ["locations", "scores", "priors"],
                    [[1, 5376], [1, 2688], [1, 2, 5376]],
                    strict=True,
                ):
                    exported.graph.node.append(
                        onnx.helper.make_node("Identity", [input_name], [output_name])
                    )
                    exported.graph.output.append(
                        onnx.helper.make_tensor_value_info(
                            output_name, onnx.TensorProto.FLOAT, shape
                        )
                    )
            onnx.checker.check_model(exported)
            onnx.save(exported, destination / f"{name}.onnx")
            # Verify converted heads against the original Intel IR, rather than
            # assuming that a successful export preserved its numeric contract.
            original = ov.Core().read_model(sources / f"{name}.xml")
            session = ort.InferenceSession(
                str(destination / f"{name}.onnx"), providers=["CPUExecutionProvider"]
            )
            if name == "detector":
                detection = next(
                    n for n in original.get_ops() if n.get_type_name() == "DetectionOutput"
                )
                ports = [detection.input_value(i) for i in range(3)]
            else:
                ports = [
                    next(p for p in original.outputs if output.name.split("/")[0] in p.get_names())
                    for output in session.get_outputs()
                ]
            reference = ov.Core().compile_model(
                ov.Model(ports, original.get_parameters()),
                "CPU",
                {"INFERENCE_PRECISION_HINT": "f32"},
            )
            test_input = (
                np.random.default_rng(42)
                .uniform(0, 255, session.get_inputs()[0].shape)
                .astype(np.float32)
            )
            expected = reference([test_input])
            actual = session.run(None, {session.get_inputs()[0].name: test_input})
            for i, output in enumerate(actual):
                np.testing.assert_allclose(output, expected[i], atol=0.001, rtol=0.001)
            print(f"{name}: OpenVINO → ONNX numeric parity verified")
        (destination / "reid.onnx").write_bytes((sources / "reid.onnx").read_bytes())
        for file in destination.glob("*.onnx"):
            session = ort.InferenceSession(str(file), providers=["CPUExecutionProvider"])
            input_tensor = session.get_inputs()[0]
            shape = {
                "reid": [1, 3, 208, 208],
                "detector": [1, 3, 256, 256],
                "attributes": [1, 3, 72, 72],
            }[file.stem]
            outputs = session.run(None, {input_tensor.name: np.zeros(shape, np.float32)})
            print(
                file.name,
                input_tensor.name,
                input_tensor.shape,
                [(o.name, v.shape) for o, v in zip(session.get_outputs(), outputs, strict=True)],
                hashlib.sha256(file.read_bytes()).hexdigest(),
            )


if __name__ == "__main__":
    main()
