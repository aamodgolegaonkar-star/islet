# Converts OpenCV Zoo's SFace (ONNX) to Core ML and checks the two agree. Used once to make
# Resources/Models/SFace.mlpackage (half precision; parity cosine 0.999994):
#   uv venv --python 3.11 && uv pip install "numpy<2" onnx onnx2torch "torch==2.7.0" "torchvision==0.22.0" coremltools onnxruntime
#   python convert-sface.py face_recognition_sface_2021dec.onnx SFace.mlpackage
# Source: https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface (Apache-2.0)
# Input: 1x3x112x112 RGB, pixel values 0-255 (OpenCV FaceRecognizerSF: blobFromImage(img, 1, (112,112), 0, swapRB=True)).
import sys, numpy as np, onnx, onnxruntime as ort, torch, coremltools as ct
from onnx2torch import convert
src, out = sys.argv[1], sys.argv[2]
model = onnx.load(src)
inp = model.graph.input[0]
print("onnx input:", inp.name, [d.dim_value for d in inp.type.tensor_type.shape.dim])
print("onnx output:", model.graph.output[0].name, [d.dim_value for d in model.graph.output[0].type.tensor_type.shape.dim])
net = convert(model).eval()
example = torch.rand(1, 3, 112, 112) * 255
traced = torch.jit.trace(net, example)
ml = ct.convert(traced, inputs=[ct.TensorType(name="face", shape=(1, 3, 112, 112))],
                outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.macOS15,
                compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
ml.short_description = "SFace face recognition (OpenCV Zoo, Apache-2.0): 112x112 aligned RGB face, 0-255 -> 128-d embedding"
ml.save(out)
sess = ort.InferenceSession(src)
worst = 1.0
for i in range(5):
    x = (np.random.rand(1, 3, 112, 112) * 255).astype(np.float32)
    a = sess.run(None, {inp.name: x})[0].ravel()
    b = np.array(ml.predict({"face": x})["embedding"]).ravel()
    cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))
    worst = min(worst, cos)
print("parity worst cosine:", round(worst, 6), "dims:", a.shape)
assert worst > 0.999
