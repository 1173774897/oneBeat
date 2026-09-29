# oneBeat Project Rules

## UI Position Adjustment Handoff

- After every change to UI position, spacing, size, alignment, or scene-layer placement, the final response must tell the user how to adjust it again.
- Always identify the exact source file and the primary property, constant, or modifier that controls the changed position.
- State the current value and the effect of increasing or decreasing it. For example: increasing `padding.left` or `x` moves content right; increasing `padding.top` or `y` moves content down.
- When multiple nested containers affect the same position, identify the preferred adjustment point first and mention any secondary constraint that may limit the usable range.
- For image-based scene layers, report both the asset path and the code property that controls its runtime position or scale.
- Keep these adjustment notes concise, but do not omit them even when the code change itself is small.
