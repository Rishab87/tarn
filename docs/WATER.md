# The water counter

Tarn counts **1.1 mL per answer** written on the Mac instead of by a cloud AI.

## Where 1.1 mL comes from

- Google measured the median Gemini Apps text prompt (Aug 2025): **0.24 Wh** of energy and **0.26 mL** of data-center cooling water. That figure covers on-site cooling only. [arXiv 2508.15734](https://arxiv.org/abs/2508.15734)
- Generating electricity also uses water. UC Riverside's study ([Li, Yang, Islam & Ren](https://arxiv.org/abs/2304.03271), v5) gives a US-average split of 2.2 mL on-site plus 14.7 mL off-site for a GPT-3-era request of about 4 Wh. That works out to about 3.7 mL of water per Wh of electricity.
- 0.24 Wh × 3.7 mL/Wh ≈ 0.88 mL off-site. Add 0.26 mL on-site and you get **≈ 1.1 mL per answer**.

## Other published figures

| Source | Per answer | Includes |
|---|---|---|
| Li et al. (UC Riverside) | 10–50 mL; 16.9 mL US average | Cooling and electricity, GPT-3-era energy (4 Wh/request) |
| Google (Aug 2025) | 0.26 mL | Cooling only |
| Sam Altman (Jun 2025) | ≈0.32 mL | Not disclosed |
| Mistral LCA (Jul 2025) | 45 mL per 400 tokens | Full lifecycle, including hardware manufacturing |
| Microsoft (Jun 2026) | 0.0–0.067 mL | Cooling only |

## Why not a bigger number

The 10–50 mL range is the most quoted, but it rests on 2023 energy assumptions about 16× higher than what Google measured in 2025. A landing page that says "50 mL per answer" gets debunked in the first Hacker News comment. Tarn counts the conservative modern figure and shows how it got there (tap the counter in the app).

## Known gaps

- The Mac's own electricity isn't subtracted: roughly 0.05–0.1 Wh per answer, about 0.2–0.4 mL. That estimate is unmeasured.
- Data centers vary a lot. New ones with dry cooling use far less water.
- To change the number, edit `Water.mlPerAnswer` and the explanation text in `Tarn/Model/Water.swift`.
