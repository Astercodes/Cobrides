# Cobridey supporting brand accents

`brand-accents.css` centralizes UI tones inspired by the supplied leaf palette. These are deliberate screen-friendly brand tones, not claims of exact pixel sampling from the reference image.

- Red `#e7352a`
- Orange `#ff731d`
- Gold `#ffb329`
- Pink `#f30078`
- Teal `#00a89c`
- Turquoise `#2cc9b7`
- Violet `#a437d5`

Warm orange/coral/rose remain the primary gradient. The supporting colors appear in category markers, decorative document covers, relationship-diagram details and Central charts. Chart tones are slightly lightened on dark cards for legibility. Labels and numeric values remain independent of decorative colors, and chart categories retain text labels.

The sidebar retains its existing warm surface and navigation colors. This stylesheet does not target editable document content, saved Vision Studio palettes, or personalized guest wedding websites. Account artwork stays distinct; its small accent rule introduces the supporting colors without changing form text or controls.

Shared public, account, participant and workspace shells load the stylesheet last; the build includes it explicitly. Central's column colors live in `central-dashboard.js`. No record data or permissions change.

## Visible surface pass

The first pass was too subtle outside Central. Version 2 uses pink, gold and turquoise journey-card surfaces, multicolor relationship artwork, stronger decorative document covers, tinted preparation cards and compact category heading bands in the portal. These changes affect UI presentation only. `brand-accents.css?v=2` ensures the new supporting stylesheet is requested after a page refresh; the sidebar and primary button gradients remain warm.
