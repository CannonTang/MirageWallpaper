#include <cmath>
#include <iostream>
#include <string_view>

import sr.text;

namespace
{

bool Near(float actual, float expected, float epsilon = 0.001f) {
    if (std::abs(actual - expected) <= epsilon) return true;
    std::cerr << "expected " << expected << ", got " << actual << '\n';
    return false;
}

} // namespace

int main() {
    // Workshop 3610728777: the dynamic clock has a 58 px logical frame but
    // only 35 px of visible ink. Bottom alignment must use 58; tight cropping
    // remains a separate compose concern.
    const sr::text::TextGeometryPolicy clock_policy {
        .frame_width        = 104.0f,
        .frame_height       = 58.0f,
        .dynamic            = true,
        .has_effect         = false,
        .preserve_text_bbox = false,
    };
    const sr::text::TextLayoutMetrics clock_metrics {
        .text_width       = 125.0f,
        .text_height      = 55.0f,
        .source_width     = 125.0f,
        .source_height    = 35.0f,
        .source_center_x  = 0.0f,
        .source_center_y  = 1.0f,
        .padding          = 0.0f,
        .source_centered  = true,
    };
    const auto clock_geometry = sr::text::ResolveTextGeometry(clock_policy, clock_metrics);
    const auto clock_anchor = sr::text::ResolveTextAnchorPosition(
        "center", "bottom", 0.0f, -46.78589f, 104.0f, 58.0f, 0.75f, 0.75f);

    bool ok = Near(clock_geometry.draw_height, 35.0f);
    ok &= Near(clock_geometry.draw_offset_y, 1.0f);
    ok &= Near(clock_anchor[1], -25.03589f);

    // The neighbouring date is centre-aligned. With the clock's authored
    // frame, the final parent-scaled ink gap is 9.32 px; substituting the
    // clock's 35 px ink height for its frame makes this negative (overlap).
    const auto date_anchor = sr::text::ResolveTextAnchorPosition(
        "center", "center", 0.0f, -54.06921f, 66.0f, 24.0f, 1.25f, 1.25f);
    constexpr float parent_scale       = 1.4f;
    constexpr float date_source_center = 0.5f;
    constexpr float date_draw_height   = 15.0f;
    const float clock_visual_center =
        clock_anchor[1] + clock_geometry.draw_offset_y * 0.75f;
    const float date_visual_center = date_anchor[1] + date_source_center * 1.25f;
    const float centre_distance =
        std::abs(clock_visual_center - date_visual_center) * parent_scale;
    const float half_heights =
        (clock_geometry.draw_height * 0.75f + date_draw_height * 1.25f) *
        parent_scale * 0.5f;
    ok &= Near(centre_distance - half_heights, 9.32164f, 0.002f);

    // An effect layer retains the font-baseline source position. Geometry
    // resolution must keep the authored 533x238 frame intact while ensuring
    // asymmetric ink remains inside its RT.
    const sr::text::TextGeometryPolicy day_policy {
        .frame_width        = 533.0f,
        .frame_height       = 238.0f,
        .dynamic            = false,
        .has_effect         = true,
        .preserve_text_bbox = false,
    };
    const sr::text::TextLayoutMetrics day_metrics {
        .text_width       = 370.0f,
        .text_height      = 165.0f,
        .source_width     = 370.0f,
        .source_height    = 144.0f,
        .source_center_x  = 0.0f,
        .source_center_y  = -11.5f,
        .padding          = 32.0f,
        .source_centered  = false,
    };
    const auto day_geometry = sr::text::ResolveTextGeometry(day_policy, day_metrics);
    ok &= Near(day_geometry.rt_width, 533.0f);
    ok &= Near(day_geometry.rt_height, 238.0f);
    ok &= Near(day_geometry.draw_width, 533.0f);
    ok &= Near(day_geometry.draw_height, 238.0f);

    // A preserved logical bbox (opaque/copy-background text) may be wider
    // than its visible ink. Its RT and UV window must cover that full bbox so
    // the background is neither clipped nor stretched.
    const sr::text::TextGeometryPolicy background_policy {
        .frame_width        = 80.0f,
        .frame_height       = 20.0f,
        .dynamic            = false,
        .has_effect         = false,
        .preserve_text_bbox = true,
    };
    const sr::text::TextLayoutMetrics background_metrics {
        .text_width       = 80.0f,
        .text_height      = 20.0f,
        .source_width     = 60.0f,
        .source_height    = 10.0f,
        .source_center_x  = 5.0f,
        .source_center_y  = 0.0f,
        .padding          = 2.0f,
        .source_centered  = false,
    };
    const auto background_geometry =
        sr::text::ResolveTextGeometry(background_policy, background_metrics);
    ok &= Near(background_geometry.rt_width, 84.0f);
    ok &= Near(background_geometry.rt_height, 24.0f);
    ok &= Near(background_geometry.draw_width, 84.0f);
    ok &= Near(background_geometry.draw_height, 24.0f);
    ok &= Near(background_geometry.uv_source_width, 84.0f);
    ok &= Near(background_geometry.uv_source_height, 24.0f);

    return ok ? 0 : 1;
}
