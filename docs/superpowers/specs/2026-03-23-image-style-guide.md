# Povver Image Generation Style Guide

**Date:** 2026-03-23
**Purpose:** Unified visual identity for AI-generated fitness imagery across landing page, ads, and App Store assets.

---

## Prompt Structure

Every image prompt follows this format:

```
Subject: [what's in the shot]
Use case: [landing page hero / app store screenshot / ad / in-app block]
Aspect ratio: [16:9 / 9:19.5 / 1:1 / 4:5]

[style block — copy-paste below]
```

---

## Style Block (copy-paste for every image)

```
Style: Cinematic fitness photography inspired by 1960s golden age bodybuilding. Moody atmosphere with retrowave undertones. Shot on analog film.

Subject treatment: Competition-level bodybuilder physique — extreme vascularity, deep muscle separation, fully pumped. Young athlete with smooth, healthy, tight skin. No face visible — either a tight crop isolating the muscle group, or an action shot of the body cropped above the chin or shot from behind. Vary skin tones across the image set for diversity.

Framing: For close-up subjects, fill the frame with the muscle group or grip — forearm on barbell, lat contraction, delt detail, quad tension. For action subjects, show the torso and body performing a compound lift (squat, deadlift, overhead press, barbell row), cropped at or above the chin.

Environment: A modern, premium gym. Dark steel racks, matte black equipment, quality rubber flooring, clean concrete or dark walls. High-end and well-maintained, not gritty or rundown. The environment is visible but stays in deep shadow, never competing with the subject. Dark and atmospheric, but you can see the space. The 1960s aesthetic comes from the film treatment and lighting, not the gym itself. Never bright, cluttered, or dirty.

Lighting: Dual-tone lighting. Primary light is warm amber/golden (#D97706 to #F59E0B range) — hard and directional for close-ups, rim/edge for action shots. Secondary light is cool teal-green (#22C59A) filling from the opposite side or spilling into shadows. Amber dominates, teal is the counterpoint. Shadows are deep but not crushed — allow detail in the dark areas. The dual-tone contrast gives a retrowave feel without going full synthwave.

Color palette: Dark backgrounds with visible environment detail. Warm amber/golden as primary light. Teal-green (#22C59A) as consistent secondary light. Overall warmth skews toward golden — like late afternoon California sun filtered through gym windows. Slightly desaturated, analog color response. No other saturated colors. The palette is strictly dark + amber + teal + warm midtones.

Film texture: Visible 35mm film grain throughout. Shot on Kodachrome — warm, slightly faded, with organic texture. The image should feel like it was taken in a 1960s Muscle Beach gym and color-graded with a retrowave sensibility. Not clean digital. Not heavy grain. Analog and vintage.

Mood: Golden age bodybuilding photography meets retrowave. Think the original Gold's Gym Venice lit with cinematic dual-tone lighting. Premium, editorial. Not stock photography. Not overly glossy or HDR-processed. Raw intensity. Power, not posing.

Imperfections: Embrace real-world imperfections — chalk residue, scuff marks, sweat, worn equipment, shallow depth of field with natural bokeh. The image should feel captured in a real moment, not digitally composed. Avoid symmetry and perfect framing. Slightly off-center compositions preferred.

Do not include: text, logos, watermarks, overlays, or UI elements baked into the image. No faces. No smiling. No bright or colorful gym environments.
```

---

## Shot Types

### Close-Up (Muscle Detail)
- **Lighting:** Hard, single-source, directional. Warm amber primary, teal secondary fill from opposite side.
- **Framing:** Tight crop on one muscle group or grip point.
- **Texture:** Subtle 35mm film grain. Slightly desaturated analog color.
- **Best for:** Ads (immediate visual punch at small sizes), in-app blocks, social media.
- **Examples:** Forearm veins gripping a loaded barbell. Back muscles mid-deadlift pull. Shoulder/delt at peak contraction. Chalk-dusted hands wrapping around a bar.

### Action (Cropped Body)
- **Lighting:** Rim/edge lighting. Warm amber primary outline, teal secondary spill in shadows.
- **Framing:** Torso or full body performing a compound lift, cropped above chin or shot from behind.
- **Texture:** Subtle 35mm film grain. Slightly desaturated analog color.
- **Best for:** Landing page hero (negative space for text), App Store screenshots, featured images.
- **Examples:** Athlete at the bottom of a heavy squat, rear view. Standing overhead press, side profile cropped at jaw. Barbell row mid-pull, back to camera.

---

## Aspect Ratios by Use Case

| Use Case | Aspect Ratio | Notes |
|----------|-------------|-------|
| Landing page hero | 16:9 or 21:9 | Wide. Leave negative space on one side for text overlay. |
| App Store screenshots | 9:19.5 | iPhone portrait. Composition works vertically. |
| Ads (Instagram/Facebook) | 1:1 or 4:5 | Square or tall. Maximum visual impact at small sizes. |
| Featured image / OG | 16:9 | Standard. Centered subject. |
| In-app block | 3:2 or 16:9 | Horizontal card. Works at thumbnail scale. |

---

## Example Prompts

### Landing Page Hero
```
Subject: Muscular athlete performing a heavy barbell squat, rear three-quarter view, mid-descent with visible quad and glute tension
Use case: Landing page hero — needs negative space on the left side for headline text overlay
Aspect ratio: 21:9

[paste style block]
```

### Instagram Ad
```
Subject: Close-up of a chalked hand gripping a loaded barbell, forearm veins visible, knurling texture on the bar
Use case: Instagram ad — must be visually striking at small sizes in a feed
Aspect ratio: 1:1

[paste style block]
```

### App Store Screenshot Background
```
Subject: Athlete performing a standing overhead press, side profile cropped at the jawline, shoulders and triceps fully engaged at lockout
Use case: App Store screenshot — UI will be overlaid on top, subject should be slightly off-center right
Aspect ratio: 9:19.5

[paste style block]
```

---

## Brand Color Reference

| Token | Hex | Role in imagery |
|-------|-----|-----------------|
| dsBackground (dark) | `#0B0D12` | Background tone |
| dsEffort | `#D97706` | Warm light source (lower bound) |
| dsEffort (dark) | `#F59E0B` | Warm light source (upper bound) |
| dsAccent (dark) | `#22C59A` | Teal secondary light source |

---

## Quality Control Checklist

Before using a generated image, verify:

- [ ] No face visible (cropped, behind, or out of frame)
- [ ] Lighting matches the shot type (hard directional for close-ups, rim for action)
- [ ] Dual-tone lighting present (amber primary + teal secondary)
- [ ] Color palette is strictly dark + amber + teal (no stray colors)
- [ ] Film grain visible but subtle (not clean digital, not overly noisy)
- [ ] Background is dark and uncluttered
- [ ] Musculature looks anatomically correct
- [ ] Equipment looks physically correct (symmetrical plates, proper bar geometry)
- [ ] No baked-in text, logos, or watermarks
- [ ] Aspect ratio matches the intended use case
- [ ] Composition leaves appropriate space for overlays (if applicable)
