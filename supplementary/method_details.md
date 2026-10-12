# Method Details

Supplement to the paper. The implementation is in `src/cts/src/` of the patched OpenROAD tree and in `flow/cts/`.

## Timing Analysis and LP Scheduling

The timing graph represents constrained launch-capture pairs among registers and I/O ports, using the worst setup and
hold slack reported by propagated-clock STA on the initial F2F clock tree. Timing checks not represented in the graph
are checked directly with STA after delay insertion.

The LP first finds the smallest worst setup violation $W^{\ast}$ and then minimizes the total setup violation subject
to $W \le 1.05\,W^{\ast}$, hold constraints with a margin, and bounded nonnegative delays $p_i$. A hold violation of
the initial tree may remain, but it may not grow under the modeled constraints.

## Timing-Driven Early-Clock Construction

Early-clock construction reconnects selected register clock pins to new leaf buffers driven through shorter clock
paths, without changing register placement or tier assignments. Each new leaf buffer is placed near the centroid of
its group on the chosen tier and is driven by an additional clock buffer connected to the clock-domain root input net,
so the group bypasses the original branch path.

The clock shift $x_i$ of sink $i$ is predicted relative to its arrival in the initial tree with its scheduled delay
$p_i$; a negative $x_i$ is an earlier arrival. The prediction also covers sinks outside a group, whose arrivals change
with the load that the early-clock drivers add to the root input net. A per-tier model of the delay change is fitted
on probe structures built on the initial tree and validated against STA on probes not used in the fit; only tiers with
a validated model are used.

Candidate groups are evaluated by the predicted reduction in total setup and hold violation, using the worst slack
$\hat s_e^q(x)$ of check class $q$ at each endpoint $e$ (register or output port) under the predicted shifts $x$:

$$
V(x)=\sum_{q\in\{\mathrm{setup},\mathrm{hold}\}}\sum_e \max\left(0,-\hat s_e^q(x)\right),
\qquad G(x)=V(0)-V(x).
$$

Nearby groups in the same clock domain are merged within limits on group size, half-perimeter wirelength and predicted
setup and hold WNS. Sets of groups taken in order of gain are evaluated with their combined driver load, and the best
evaluated set after wirelength and tier-crossing penalties is constructed.

## Shared Delay Chains

After early-clock construction, the LP is solved again for the delay targets $a_i$. Registers sharing a branch driver
and destination tier use a common delay chain and connect to its taps. Stage delays are taken from the Liberty tables
at the stage load (sink pin capacitance, Steiner wire capacitance and the input of the next stage), with the slew
propagated along the chain. Tap assignments and stage sizes are iteratively refined to reduce the asymmetric cost

$$
c_i=\max(0,a_i-\hat a_i)+\max(0,\hat a_i-H_i)+0.1\max(0,\hat a_i-a_i),
$$

where $\hat a_i$ is the delivered delay and $H_i$ the hold budget of register $i$. The delivered delay of a register
can differ from its target.

## Clock Tree Refinement

Buffer resizing and clock-path reconnection are evaluated with whole-design STA. A change is retained when it improves
hold timing within prescribed limits on setup TNS loss, setup and hold WNS, and electrical violations.

Buffers outside their load-pin bounding boxes are relocated toward the load-pin centroid, using legal sites on the
same tier. A move is retained when it improves the combined setup and hold TNS within the setup and hold WNS
tolerances.
