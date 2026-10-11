# Supplementary Results

Experiments that are not reported in the paper. All results use the ten cases, placements and clock periods of
Table I of the paper (`./run_cts.sh --list`).

## Realization of LP Delay Targets

Delay realization is evaluated after delivery and before refinement. For sink $i$, $a_i$ is the LP target and
$\hat a_i$ the change in late clock latency relative to the reference tree. For the requested sinks
$\mathcal R=\{i : a_i > 5\,\mathrm{ps}\}$, the target agreement is

$$
F_{\mathrm{match}} = 100\left(1 - \frac{\sum_{i\in\mathcal R}|\hat a_i - a_i|}{\sum_{i\in\mathcal R}\left(|\hat a_i| + a_i\right)}\right)
$$

This score ranges from 0 to 100 %, penalizes both underdelivery and overdelivery, and equals 100 % only when all
requested targets are matched. The median absolute error $|e_i| = |\hat a_i - a_i|$ expresses the deviation in ps.

| Platform | Design | $\lvert\mathcal R\rvert$ | $F_{\mathrm{match}}$ (%) | median $\lvert e_i\rvert$ (ps) |
|---|---|---:|---:|---:|
| A7/A7 | AES | 118 | 94.2 | 4.4 |
| A7/A7 | JPEG | 450 | 87.8 | 8.0 |
| A7/A7 | IBEX | 775 | 93.9 | 4.4 |
| A7/A7 | SWERV | 1589 | 93.6 | 3.8 |
| A7/A7 | ARIANE | 7287 | 86.3 | 6.7 |
| A7/N45 | AES | 117 | 89.5 | 9.4 |
| A7/N45 | JPEG | 3911 | 85.0 | 16.4 |
| A7/N45 | IBEX | 992 | 76.8 | 28.8 |
| A7/N45 | SWERV | 616 | 84.1 | 14.2 |
| A7/N45 | ARIANE | 3731 | 86.4 | 14.3 |

Target agreement is 76.8–94.2 %. Median absolute errors are 3.8–8.0 ps on A7/A7 and 9.4–28.8 ps on A7/N45, with
the largest error in A7/N45 IBEX.
