# Converts Minivision's MiniFASNet anti-spoofing models (PyTorch) to Core ML and checks the
# two agree. Used once to make Resources/Models/AntiSpoof27.mlpackage and AntiSpoof40.mlpackage
# (half precision, softmax included):
#   uv venv --python 3.11 && uv pip install "numpy<2" "torch==2.7.0" coremltools
#   git clone --depth 1 https://github.com/minivision-ai/Silent-Face-Anti-Spoofing repo   (Apache-2.0)
#   python -I convert-minifasnet.py repo Resources/Models
# Only repo/src/model_lib/MiniFASNet.py (plain layer definitions, reviewed) is loaded, by path;
# the weights load with weights_only=True, so the pickles can't run code.
# Input "patch": 1x3x80x80, BGR, pixel values 0-255 (the repo's ToTensor doesn't divide by 255).
# Output "probabilities": [fake (print), real, fake (screen)].
import importlib.util, sys, os, numpy as np, torch, coremltools as ct

repo, out = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("minifasnet", os.path.join(repo, "src/model_lib/MiniFASNet.py"))
fas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fas)

models = [
    ("2.7_80x80_MiniFASNetV2.pth", fas.MiniFASNetV2, "AntiSpoof27"),
    ("4_0_0_80x80_MiniFASNetV1SE.pth", fas.MiniFASNetV1SE, "AntiSpoof40"),
]
for weights, make, name in models:
    net = make(conv6_kernel=(5, 5))  # (80 + 15) // 16, as the repo's get_kernel
    state = torch.load(os.path.join(repo, "resources/anti_spoof_models", weights), map_location="cpu", weights_only=True)
    net.load_state_dict({k[7:] if k.startswith("module.") else k: v for k, v in state.items()})
    net.eval()
    full = torch.nn.Sequential(net, torch.nn.Softmax(dim=1)).eval()
    example = torch.rand(1, 3, 80, 80) * 255
    traced = torch.jit.trace(full, example)
    ml = ct.convert(traced, inputs=[ct.TensorType(name="patch", shape=(1, 3, 80, 80))],
                    outputs=[ct.TensorType(name="probabilities")], minimum_deployment_target=ct.target.macOS15,
                    compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    ml.short_description = f"MiniFASNet ({weights}, Minivision, Apache-2.0): 80x80 BGR 0-255 face patch -> [fake, real, fake]"
    ml.save(os.path.join(out, f"{name}.mlpackage"))
    worst = 0.0
    with torch.no_grad():
        for _ in range(8):
            x = (torch.rand(1, 3, 80, 80) * 255)
            a = full(x).numpy().ravel()
            b = np.array(ml.predict({"patch": x.numpy()})["probabilities"]).ravel()
            worst = max(worst, float(np.abs(a - b).max()))
    print(name, "parity worst abs diff:", round(worst, 5))
    assert worst < 0.02
