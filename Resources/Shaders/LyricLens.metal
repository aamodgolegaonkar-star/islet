// The on-screen lyrics' lens: a barrel distortion over the whole band of words, so the
// middle reads at full size and rows toward the top and bottom curve and shrink, as if the
// words were seen through a glass dome. Compiled into LyricLens.metallib by build-app.sh
// and used through SwiftUI's distortionEffect.

#include <metal_stdlib>
using namespace metal;

/// Where to sample for the pixel at `position`. `size` is the band's size; `strength` is how
/// much the edges shrink (0.45: to about 0.4× at the rim) and `power` how quickly the
/// effect builds from the middle (2.2: barely at first, then fast).
[[ stitchable ]] float2 lyricLens(float2 position, float2 size, float strength, float power) {
    float2 center = size * 0.5;
    float2 offset = position - center;
    // Normalised per axis, so the lens fits the band's shape instead of being a circle.
    float2 unit = offset / max(center, float2(1.0));
    float radius = length(unit);
    return center + offset * (1.0 + strength * pow(radius, power));
}
