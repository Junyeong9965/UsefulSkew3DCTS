// Fail-closed checks of the flow: CTS inputs, LP targets, the STA guard of unsupported endpoints, LP bounds.
//
//   cts_checks inputs <results_dir>               native graph valid and bound to the Phase-1 reference
//   cts_checks guarded-inputs <results_dir>       guarded variant (env CTS_STA_GUARD_MANIFEST)
//   cts_checks targets <results_dir>              independent re-check of the LP targets; TARGET_VERIFICATION.json
//   cts_checks guard-endpoints <G_dir> <endpoints.tsv>
//   cts_checks guard-manifest <case> <G_dir> <phase1_dir> <baseline_reports> <guard_dir>
//   cts_checks guard-eval <baseline_reports> <candidate_reports> <policy.json> <out.json>
//   cts_checks lp-bounds <plan.tsv|""> <graph.csv> <io.csv> <out.csv> <phase1_dir>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <map>
#include <set>

#include "flowutil.h"

using namespace flow;

namespace {
void need(bool cond, const std::string& msg)
{
  if (!cond) fail("assertion failed: " + msg);
}

// ---------------------------------------------------------------- inputs
int inputs_main(const std::string& R)
{
  auto t = std::chrono::steady_clock::now();
  std::string f = realpath_of(join_path(R, "pre_cts_ff_timing_graph.csv")), i = realpath_of(join_path(R, "pre_cts_io_timing_edges.csv"));
  need(dirname_of(f) == dirname_of(i), "FF/IO states differ");
  std::string N = dirname_of(f);
  for (const char* kind : {"ff", "io"}) need(starts_with(read_text(join_path(R, std::string(kind) + "_admission.status")), "VALID\n"), "BLOCKED admission");
  std::map<std::string, std::string> receipt;
  for (auto& line : read_lines(join_path(dirname_of(N), "INPUTS.sha256"))) {
    size_t sp = line.find_first_of(" \t");
    if (sp == std::string::npos) continue;
    size_t b = line.find_first_not_of(" \t", sp);
    if (b == std::string::npos) continue;
    std::string path = line.substr(b);
    if (!path.empty() && path[0] == '*') path = path.substr(1);
    receipt[path] = line.substr(0, sp);
  }
  for (const char* fn : {"phase1.odb", "phase1.sdc"}) {
    std::string p = realpath_of(join_path(R, fn));
    need(receipt.count(p) > 0, "Phase1 not bound to native producer: " + p);
    need(sha256_file(p) == receipt[p], "Phase1 hash drift");
  }
  const char* keys[] = {"setup_tns_ps", "setup_wns_ps", "hold_tns_ps", "hold_wns_ps"};
  std::vector<double> ref;
  { std::istringstream ss(read_text(join_path(R, "phase1.metrics"))); std::string w; while (ref.size() < 4 && ss >> w) ref.push_back(to_double(w)); }
  Table m = read_table(join_path(dirname_of(N), "reports/metrics.csv"));
  std::vector<double> delta;
  for (int k = 0; k < 4; ++k) delta.push_back(to_double(m.at(0, keys[k])) - ref.at(k));
  double mx = 0;
  for (double d : delta) mx = std::max(mx, std::fabs(d));
  need(mx < .001, "Phase1 reload mismatch");
  J seal = J::Obj();
  for (auto& p : {f, i, join_path(N, "ff_admission.status"), join_path(N, "io_admission.status")}) seal.set(basename_of(p), J::S(sha256_file(p)));
  std::sort(seal.o.begin(), seal.o.end(), [](auto& a, auto& b) { return a.first < b.first; });
  std::string sp = join_path(N, "NATIVE_INPUT_SEAL.json");
  if (path_exists(sp)) {
    J old = json_load(sp);
    bool same = old.o.size() == seal.o.size();
    for (auto& kv : seal.o) if (!old.has(kv.first) || old.get(kv.first).s != kv.second.s) same = false;
    need(same, "Native graph/receipt changed after first use");
  } else write_text(sp, seal.dump(2));
  double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count();
  J out = J::Obj();
  out.set("status", J::S("PASS"));
  J dl = J::Arr();
  for (double d : delta) dl.push(J::D(d));
  out.set("phase1_reload_delta_ps", dl); out.set("seal", seal); out.set("validation_seconds", J::D(secs));
  out.set("producer_receipt", J::S(join_path(dirname_of(N), "INPUTS.sha256")));
  write_text(join_path(R, "INPUT_VERIFICATION.json"), out.dump(2));
  std::printf("INPUT_VALIDATION_SECONDS %s\n", py_repr(secs).c_str());
  return 0;
}

// ---------------------------------------------------------------- guarded inputs
int guarded_inputs_main(const std::string& R)
{
  const char* menv = std::getenv("CTS_STA_GUARD_MANIFEST");
  need(menv != nullptr, "CTS_STA_GUARD_MANIFEST not set");
  std::string M = menv;
  J m = json_load(M);
  need(m.get("status").s == "BASELINE_CERTIFIED", "manifest status");
  for (auto& kv : m.get("sha256").o) need(sha256_file(kv.first) == kv.second.s, "guard input drift: " + kv.first);
  for (const char* kind : {"ff", "io"}) {
    std::string st = join_path(R, std::string(kind) + "_admission.status");
    need(starts_with(read_text(st), "GUARDED\n"), "status not GUARDED");
    need(sha256_file(st) == m.get("guarded_status_sha256").get(kind).s, "guarded status hash");
    need(starts_with(read_text(join_path(m.get("native_dir").s, std::string("results/") + kind + "_admission.status")), "BLOCKED\n"), "native status not BLOCKED");
  }
  for (const char* f : {"pre_cts_ff_timing_graph.csv", "pre_cts_io_timing_edges.csv"})
    need(realpath_of(join_path(R, f)) == realpath_of(join_path(m.get("native_dir").s, std::string("results/") + f)), "graph file not the native one");
  for (const char* f : {"phase1.odb", "phase1.sdc"}) need(realpath_of(join_path(R, f)) == realpath_of(join_path(m.get("phase1_dir").s, f)), "phase1 file differs");
  std::string base = m.get("baseline_guard_dir").s;
  std::set<std::pair<std::string, std::string>> q, u;
  { Table t = read_table(join_path(base, "guard_queries.csv")); for (auto& r : t.rows) q.emplace(r[t.col("endpoint")], r[t.col("mode")]); }
  for (auto& e : m.get("unsupported_endpoints").a) u.emplace(e.a.at(0).s, e.a.at(1).s);
  need(q == u, "guard endpoint set differs from the manifest");
  Table rows = read_table(join_path(base, "guard_paths.csv"));
  need((long long) rows.rows.size() == m.get("baseline_path_count").i, "baseline path count");
  json_load(join_path(dirname_of(dirname_of(dirname_of(M))), "GUARD_POLICY.json"));
  double mn = INFINITY;
  for (auto& r : rows.rows) mn = std::min(mn, to_double(r[rows.col("slack_ps")]));
  need(mn >= 0.0, "baseline violates an unsupported check");
  const char* keys[] = {"setup_tns_ps", "setup_wns_ps", "hold_tns_ps", "hold_wns_ps"};
  std::vector<double> ref;
  { std::istringstream ss(read_text(join_path(R, "phase1.metrics"))); std::string w; while (ref.size() < 4 && ss >> w) ref.push_back(to_double(w)); }
  Table probed = read_table(join_path(m.get("native_dir").s, "reports/metrics.csv"));
  double mx = 0;
  for (int k = 0; k < 4; ++k) mx = std::max(mx, std::fabs(to_double(probed.at(0, keys[k])) - ref.at(k)));
  need(mx < .001, "Phase1 reload mismatch");
  J out = J::Obj();
  out.set("status", J::S("PASS")); out.set("classification", J::S("STA_GUARDED")); out.set("manifest", J::S(M)); out.set("manifest_sha256", J::S(sha256_file(M)));
  write_text(join_path(R, "INPUT_VERIFICATION.json"), out.dump(2));
  std::printf("GUARDED_INPUT_PASS %s\n", M.c_str());
  return 0;
}

// ---------------------------------------------------------------- LP targets
int targets_main(const std::string& R)
{
  const double tol = 0.0000021;   // ns: 2.1 fs, including two CSV rounding errors
  std::map<std::string, double> T;
  std::vector<std::string> Torder;
  { Table t = read_table(join_path(R, "pre_cts_skew_targets.csv")); for (auto& r : t.rows) { if (!T.count(r[t.col("ff_name")])) Torder.push_back(r[t.col("ff_name")]); T[r[t.col("ff_name")]] = to_double(r[t.col("target_arrival_ns")]); } }
  bool no_change_certificate = false;
  std::map<std::string, std::pair<std::string, std::string>> V;   // ff -> (upper_ns, Vj_ns)
  std::string vp = join_path(R, "lp_endpoint_solution.csv");
  if (path_exists(vp)) {
    Table t = read_table(vp);
    for (auto& r : t.rows) V[r[t.col("ff_name")]] = {r[t.col("upper_ns")], r[t.col("Vj_ns")]};
  } else {
    for (auto& kv : T) need(kv.second == 0, "Missing optimizer certificate for nonzero schedule");
    no_change_certificate = true;
    for (auto& kv : T) V[kv.first] = {".05", "0"};
  }
  J bad = J::Arr();
  std::map<std::string, long long> counts{{"ff_hold", 0}, {"pi_hold", 0}, {"setup", 0}};
  double worst = 0., residual_sum = 0., baseline_sum = 0.;
  std::unordered_map<std::string, double> setup;
  std::vector<std::string> setup_order;   // first-occurrence order (summation order)
  auto check = [&](const char* label, double excess, const J& row) {
    worst = std::max(worst, excess);
    if (excess > tol && bad.a.size() < 40) { J b = J::Obj(); b.set("kind", J::S(label)); b.set("excess_ns", J::D(excess)); b.set("row", row); bad.push(b); }
  };
  for (auto& n : Torder) { check("lower_bound", -T[n], J::S(n)); check("global_upper", T[n] - .05, J::S(n)); }
  {
    Table g = read_table(join_path(R, "pre_cts_ff_timing_graph.csv"));
    int cf = g.col("from_ff"), ct = g.col("to_ff"), cmin = g.col("slack_min_ns"), cmax = g.col("slack_max_ns");
    long long num = 2;
    for (auto& r : g.rows) {
      const std::string& i = r[cf];
      const std::string& j = r[ct];
      if (!T.count(i) || !T.count(j)) fail("Missing target (" + i + ", " + j + ")");
      double a = T[i], b = T[j];
      check("delivery_bound", a - to_double(V[i].first), J::S(i));
      double s = to_double(r[cmin]);
      if (std::isfinite(s)) {
        double h = s - .012, cap = std::max(0., -h), required = std::max(0., b - a - h);
        check("FF_hold_residual", required - cap, J::I(num));
        counts["ff_hold"]++; residual_sum += required; baseline_sum += cap;
      }
      double sm = to_double(r[cmax]);
      if (std::isfinite(sm)) {
        check("setup_epigraph", a - b - to_double(V[j].second) - (sm - .002), J::I(num));
        counts["setup"]++;
        double v = sm - .002 + b - a;
        auto it = setup.find(j);
        if (it == setup.end()) { setup_order.push_back(j); setup[j] = std::min(0., v); }
        else it->second = std::min(it->second, v);
      }
      ++num;
    }
  }
  {
    Table io = read_table(join_path(R, "pre_cts_io_timing_edges.csv"));
    int cn = io.col("ff_name"), ch = io.col("slack_hold_ns"), ce = io.col("edge_type");
    long long num = 2;
    for (auto& r : io.rows) {
      const std::string& name = r[cn];
      if (!T.count(name)) fail("IO-only target missing " + name);
      double s;
      try { s = to_double(r[ch]); } catch (std::exception&) { ++num; continue; }
      if (r[ce] == "PI_TO_FF" && std::isfinite(s)) {
        counts["pi_hold"]++;
        double a = T[name], cap = std::max(0., -s), required = std::max(0., a - s);
        check("PI_hold_residual", required - cap, J::I(num));
        check("PI_sigma_clip", a - std::max(0., s - .025), J::I(num));
        residual_sum += required; baseline_sum += cap;
      }
      ++num;
    }
  }
  double setup_sum = 0.0;
  bool first = true;
  for (auto& j : setup_order) { if (first) { setup_sum = setup[j]; first = false; } else setup_sum += setup[j]; }
  J out = J::Obj();
  out.set("status", J::S(bad.a.empty() ? "PASS" : "FAIL")); out.set("no_change_algebraic_certificate", J::B(no_change_certificate));
  out.set("units", J::S("ns"));
  J c = J::Obj();
  for (const char* k : {"ff_hold", "pi_hold", "setup"}) c.set(k, J::I(counts[k]));
  out.set("counts", c); out.set("worst_excess_ns", J::D(worst)); out.set("tolerance_ns", J::D(tol));
  out.set("baseline_residual_cap_sum_ns", J::D(baseline_sum)); out.set("minimum_required_residual_sum_ns", J::D(residual_sum));
  out.set("graph_setup_endpoint_sum_ns", J::D(setup_sum)); out.set("graph_setup_is_not_full_STA_TNS", J::B(true));
  out.set("no_change_feasible_by_construction", J::B(true)); out.set("violations", bad);
  write_text(join_path(R, "TARGET_VERIFICATION.json"), out.dump(2));
  std::printf("%s\n", out.dump(2).c_str());
  return bad.a.empty() ? 0 : 1;
}

// ---------------------------------------------------------------- guard inputs
std::set<std::pair<std::string, std::string>> endpoints_of(const std::string& native, std::map<std::string, std::string>& original)
{
  std::set<std::pair<std::string, std::string>> ep;
  for (const char* kind : {"ff", "io"}) {
    original[kind] = read_text(join_path(native, std::string("results/") + kind + "_admission.status"));
    need(starts_with(original[kind], "BLOCKED\n") || starts_with(original[kind], "VALID\n"), "admission status");
    Table t = read_table(join_path(native, std::string("results/") + kind + "_admission_events.csv"));
    bool has_mode = t.index.count("mode") > 0;
    for (auto& r : t.rows) {
      if (r[t.col("status")] != "unsupported") continue;
      if (has_mode && (r[t.col("mode")] == "0" || r[t.col("mode")] == "1")) ep.emplace(r[t.col("endpoint")], r[t.col("mode")] == "1" ? "max" : "min");
      else { ep.emplace(r[t.col("endpoint")], "max"); ep.emplace(r[t.col("endpoint")], "min"); }
    }
  }
  return ep;
}

int guard_endpoints_main(const std::string& native, const std::string& out)
{
  std::map<std::string, std::string> orig;
  auto ep = endpoints_of(native, orig);
  need(!ep.empty(), "no unsupported endpoint: this case does not need the guard path");
  std::string s = "endpoint\tmode\n";
  for (auto& e : ep) s += e.first + "\t" + e.second + "\n";
  write_text(out, s);
  std::printf("guard endpoints %zu\n", ep.size());
  return 0;
}

void relink(const std::string& dst, const std::string& src)
{
  if (path_exists(dst) || is_link(dst)) ::unlink(dst.c_str());
  if (::symlink(src.c_str(), dst.c_str()) != 0) fail("cannot link " + dst);
}

int guard_manifest_main(const std::string& cas, const std::string& native, const std::string& phase1, const std::string& baseline, const std::string& W)
{
  need(path_exists(join_path(baseline, "metrics.csv")) && path_exists(join_path(baseline, "guard_paths.csv")), "baseline reports");
  std::string out = join_path(W, "inputs/" + cas);
  mkdirs(out);
  std::map<std::string, std::string> original;
  auto endpoints = endpoints_of(native, original);
  for (const char* kind : {"ff", "io"}) {
    std::string p = join_path(out, std::string(kind) + "_admission.status");
    if (path_exists(p) || is_link(p)) ::unlink(p.c_str());
    std::string nat = join_path(native, std::string("results/") + kind + "_admission.status");
    if (starts_with(original[kind], "BLOCKED\n")) write_text(p, "GUARDED\noriginal_native_status_sha256=" + sha256_file(nat) + "\n");
    else if (::symlink(nat.c_str(), p.c_str()) != 0) fail("cannot link " + p);
  }
  std::set<std::pair<std::string, std::string>> q;
  { Table t = read_table(join_path(baseline, "guard_queries.csv")); for (auto& r : t.rows) q.emplace(r[t.col("endpoint")], r[t.col("mode")]); }
  need(q == endpoints, "guard endpoint coverage mismatch");
  long long path_count = (long long) read_table(join_path(baseline, "guard_paths.csv")).rows.size();
  need(path_count > 0, "no guard path");
  J policy = json_load(join_path(W, "GUARD_POLICY.json"));
  need(policy.get("positive_guard_ps").num() > 0, "positive_guard_ps");
  for (const char* f : {"pre_cts_ff_timing_graph.csv", "pre_cts_io_timing_edges.csv"}) relink(join_path(out, f), join_path(native, std::string("results/") + f));
  for (const char* f : {"phase1.odb", "phase1.sdc", "pre_cts_leaf_bounds.csv", "cts_base_latency.csv", "phase1_leaf_groups.csv", "phase1.metrics"}) {
    std::string p = join_path(phase1, f);
    if (path_exists(p)) relink(join_path(out, f), p);
  }
  std::vector<std::string> sealed;
  for (const char* f : {"pre_cts_ff_timing_graph.csv", "pre_cts_io_timing_edges.csv", "ff_admission.status", "io_admission.status",
                        "ff_admission_events.csv", "io_admission_events.csv"})
    sealed.push_back(join_path(native, std::string("results/") + f));
  sealed.push_back(join_path(baseline, "guard_paths.csv")); sealed.push_back(join_path(baseline, "guard_queries.csv"));
  sealed.push_back(join_path(W, "GUARD_POLICY.json")); sealed.push_back(join_path(phase1, "phase1.odb")); sealed.push_back(join_path(phase1, "phase1.sdc"));
  J man = J::Obj();
  man.set("case", J::S(cas)); man.set("classification", J::S("STA_GUARDED")); man.set("status", J::S("BASELINE_CERTIFIED"));
  man.set("phase1_dir", J::S(phase1)); man.set("native_dir", J::S(native)); man.set("baseline_guard_dir", J::S(baseline));
  J ue = J::Arr();
  for (auto& e : endpoints) { J p = J::Arr(); p.push(J::S(e.first)); p.push(J::S(e.second)); ue.push(p); }
  man.set("unsupported_endpoints", ue); man.set("baseline_path_count", J::I(path_count));
  J gs = J::Obj();
  for (const char* kind : {"ff", "io"}) gs.set(kind, J::S(sha256_file(join_path(out, std::string(kind) + "_admission.status"))));
  man.set("guarded_status_sha256", gs);
  J sh = J::Obj();
  for (auto& p : sealed) sh.set(p, J::S(sha256_file(p)));
  man.set("sha256", sh);
  write_text(join_path(out, "guard_manifest.json"), man.dump(2));
  std::string s = "endpoint\tmode\n";
  for (auto& e : endpoints) s += e.first + "\t" + e.second + "\n";
  write_text(join_path(out, "guard_endpoints.tsv"), s);
  std::printf("%s\n", out.c_str());
  return 0;
}

// ---------------------------------------------------------------- guard evaluation
int guard_eval_main(const std::string& baseline, const std::string& candidate, const std::string& policyf, const std::string& outf)
{
  J policy = json_load(policyf);
  double floor_ = policy.get("positive_guard_ps").num(), tol = policy.get("numerical_tolerance_ps").num();
  using Key = std::pair<std::string, std::string>;
  struct Row { std::vector<std::string> f; double slack; };
  struct Checks { std::map<Key, std::vector<Row>> by; std::vector<std::string> header; };
  auto read = [&](const std::string& root) {
    Checks c;
    Table t = read_table(join_path(root, "guard_paths.csv"));
    c.header = t.header;
    int ce = t.col("endpoint"), cm = t.col("mode"), cs = t.col("slack_ps");
    for (auto& r : t.rows) c.by[{r[ce], r[cm]}].push_back({r, to_double(r[cs])});
    Table q = read_table(join_path(root, "guard_queries.csv"));
    std::set<Key> qk;
    for (auto& r : q.rows) {
      Key k{r[q.col("endpoint")], r[q.col("mode")]};
      need(r[q.col("saturated")] == "0" && to_int(r[q.col("path_count")]) == (long long) c.by[k].size(), "guard query consistency");
      need(!c.by[k].empty(), "no active check for an endpoint");
      qk.insert(k);
    }
    std::set<Key> ck;
    for (auto& kv : c.by) ck.insert(kv.first);
    need(ck == qk, "checks / queries differ");
    return c;
  };
  Checks b = read(baseline), c = read(candidate);
  { std::set<Key> kb, kc; for (auto& kv : b.by) kb.insert(kv.first); for (auto& kv : c.by) kc.insert(kv.first); need(kb == kc, "unsupported endpoint or mode disappeared"); }
  J result = J::Obj();
  result.set("status", J::S("PASS")); result.set("policy", policy); result.set("checks", J::Arr());
  long long na = 0, nb = 0;
  for (auto& kv : b.by) na += (long long) kv.second.size();
  for (auto& kv : c.by) nb += (long long) kv.second.size();
  result.set("all_active_paths_A", J::I(na)); result.set("all_active_paths_B", J::I(nb));
  int cst = -1, crl = -1;
  for (size_t i = 0; i < b.header.size(); ++i) { if (b.header[i] == "startpoint") cst = (int) i; if (b.header[i] == "role") crl = (int) i; }
  need(cst >= 0 && crl >= 0, "guard_paths columns");
  bool status_pass = true;
  for (auto& kv : b.by) {
    const Key& key = kv.first;
    auto& before = kv.second;
    auto& after = c.by[key];
    std::set<Key> sb, sa;
    for (auto& r : before) sb.emplace(r.f[cst], r.f[crl]);
    for (auto& r : after) sa.emplace(r.f[cst], r.f[crl]);
    std::vector<Key> missing;
    for (auto& k : sb) if (!sa.count(k)) missing.push_back(k);
    if (!missing.empty()) status_pass = false;
    double amin = INFINITY, bmin = INFINITY;
    for (auto& r : before) amin = std::min(amin, r.slack);
    for (auto& r : after) bmin = std::min(bmin, r.slack);
    double threshold = amin >= 0 ? std::min(floor_, amin) : amin;
    J neg = J::Arr();
    bool neg_ok = true;
    if (amin < 0) {
      std::map<Key, std::vector<double>> gb, ga;
      std::vector<Key> gorder;
      for (auto& r : before) { Key g{r.f[cst], r.f[crl]}; if (!gb.count(g)) gorder.push_back(g); gb[g].push_back(r.slack); }
      for (auto& r : after) ga[{r.f[cst], r.f[crl]}].push_back(r.slack);
      for (auto& g : gorder) {
        double old = *std::min_element(gb[g].begin(), gb[g].end());
        if (old >= 0) continue;
        bool has = ga.count(g) && !ga[g].empty();
        double nw = has ? *std::min_element(ga[g].begin(), ga[g].end()) : 0.0;
        bool pass = has && nw >= old - tol;
        if (!pass) neg_ok = false;
        J e = J::Obj();
        e.set("startpoint", J::S(g.first)); e.set("role", J::S(g.second)); e.set("baseline_min_ps", J::D(old));
        e.set("candidate_min_ps", has ? J::D(nw) : J::Null()); e.set("pass", J::B(pass));
        neg.push(e);
      }
    }
    bool passed = bmin >= threshold - tol && missing.empty() && neg_ok;
    if (!passed) status_pass = false;
    J ck = J::Obj();
    ck.set("endpoint", J::S(key.first)); ck.set("mode", J::S(key.second)); ck.set("baseline_count", J::I((long long) before.size()));
    ck.set("candidate_count", J::I((long long) after.size())); ck.set("baseline_min_ps", J::D(amin)); ck.set("candidate_min_ps", J::D(bmin));
    ck.set("threshold_ps", J::D(threshold)); ck.set("pass", J::B(passed));
    J ms = J::Arr();
    for (size_t i = 0; i < missing.size() && i < 20; ++i) { J p = J::Arr(); p.push(J::S(missing[i].first)); p.push(J::S(missing[i].second)); ms.push(p); }
    ck.set("missing_start_roles", ms); ck.set("existing_negative_checks", neg);
    const Row* worst = &after[0];
    for (auto& r : after) if (r.slack < worst->slack) worst = &r;
    J w = J::Obj();
    for (size_t i = 0; i < c.header.size(); ++i) w.set(c.header[i], c.header[i] == "slack_ps" ? J::D(worst->slack) : J::S(worst->f[i]));
    ck.set("candidate_worst", w);
    result.o[2].second.push(ck);
  }
  result.set("status", J::S(status_pass ? "PASS" : "FAIL"));
  write_text(outf, result.dump(2));
  std::printf("%s\n", status_pass ? "PASS" : "FAIL");
  return status_pass ? 0 : 1;
}

// ---------------------------------------------------------------- LP increment bounds (stage D)
int lp_bounds_main(const std::string& plan, const std::string& graph, const std::string& io, const std::string& out, const std::string& pdir)
{
  std::set<std::string> zero;
  if (!plan.empty()) {
    Table t = read_table(plan, '\t');
    for (auto& r : t.rows) for (auto& mp : split(r[t.col("members")], ';')) if (!mp.empty()) zero.insert(inst_of(mp));
  }
  std::set<std::string> names, ports;
  { Table g = read_table(graph); for (auto& e : g.rows) { names.insert(e[g.col("from_ff")]); names.insert(e[g.col("to_ff")]); } }
  { Table t = read_table(io); for (auto& e : t.rows) { names.insert(e[t.col("ff_name")]); names.insert(e[t.col("port_name")]); ports.insert(e[t.col("port_name")]); } }
  std::set<std::string> leaf, macros;
  { Table t = read_table(join_path(pdir, "phase1_leaf_groups.csv")); for (auto& r : t.rows) leaf.insert(inst_of(r[t.col("sink")])); }
  for (auto& l : read_lines(join_path(pdir, "macros.txt"))) { std::string s = strip(l); if (!s.empty()) macros.insert(s); }
  std::set<std::string> regs, nonleaf, mac;
  for (auto& n : names) if (!ports.count(n)) regs.insert(n);
  for (auto& n : regs) { if (!leaf.count(n) && !macros.count(n)) nonleaf.insert(n); if (macros.count(n)) mac.insert(n); }
  {
    std::string s = "name,reason\n";
    for (auto& n : nonleaf) s += n + ",not_a_phase1_leaf_sink\n";
    for (auto& n : mac) s += n + ",macro\n";
    write_text(join_path(dirname_of(out), "lp_undeliverable.csv"), s);
  }
  std::printf("LP deliverable: %zu register/macro nodes, %zu not a Phase-1 leaf sink, %zu macros -> bound 0\n", regs.size(), nonleaf.size(), mac.size());
  zero.insert(nonleaf.begin(), nonleaf.end());
  zero.insert(mac.begin(), mac.end());
  std::string s = "ff_name,bound_ns\n";
  size_t zn = 0;
  for (auto& n : names) { bool z = zero.count(n) > 0; zn += z; s += n + "," + (z ? "0" : "1.0") + "\n"; }
  write_text(out, s);
  std::printf("LP bounds: %zu nodes, %zu zero (early-group members %zu)\n", names.size(), zn, zero.size());
  return 0;
}
}  // namespace

int main(int argc, char** argv)
{
  try {
    std::string cmd = argc > 1 ? argv[1] : "";
    std::vector<std::string> a;
    for (int i = 2; i < argc; ++i) a.push_back(argv[i]);
    if (cmd == "inputs" && a.size() == 1) return inputs_main(a[0]);
    if (cmd == "guarded-inputs" && a.size() == 1) return guarded_inputs_main(a[0]);
    if (cmd == "targets" && a.size() == 1) return targets_main(a[0]);
    if (cmd == "guard-endpoints" && a.size() == 2) return guard_endpoints_main(a[0], a[1]);
    if (cmd == "guard-manifest" && a.size() == 5) return guard_manifest_main(a[0], a[1], a[2], a[3], a[4]);
    if (cmd == "guard-eval" && a.size() == 4) return guard_eval_main(a[0], a[1], a[2], a[3]);
    if (cmd == "lp-bounds" && a.size() == 5) return lp_bounds_main(a[0], a[1], a[2], a[3], a[4]);
    std::fprintf(stderr, "usage: cts_checks inputs|guarded-inputs|targets|guard-endpoints|guard-manifest|guard-eval|lp-bounds ...\n");
    return 2;
  } catch (std::exception& e) {
    std::fprintf(stderr, "cts_checks: %s\n", e.what());
    return 1;
  }
}
