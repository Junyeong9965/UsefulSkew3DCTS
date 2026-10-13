// Route-input checks, final ON/OFF selection and the reports of one case.
//
//   cts_select output <case> <run_dir> <OFF route-input dir> <ON route-input dir>    -> <run_dir>/out/select.json
//   cts_select plan <case> <arm DEF> <reference DEF> [plan.tsv|-] [out.json]
//   cts_select overlap --def D --lefdir L [--lefdir L2] [--ref R] [--clock-list F] [--ng45-grid G] --out O [--bin N]
//   cts_select report <run_dir> <case> <output arm> <output arm dir> <reason> [plan]
//   cts_select multihub <case> <out.json> "<k> <select.json> <arm dir>" ...   (multi-hub prefix verdict)
//   cts_select jget <file.json> <key>                                           (top-level value, for shell scripts)
//   cts_select gate <case> <decide dir> <out.json>                               (ON-benefit gate)
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <map>
#include <regex>
#include <set>

#include "flowutil.h"

using namespace flow;

namespace {
// last row of a CSV as {column: value}
std::vector<std::pair<std::string, double>> last_row(const std::string& p)
{
  Table t = read_table(p);
  if (t.rows.empty()) fail("empty " + p);
  std::vector<std::pair<std::string, double>> out;
  for (size_t i = 0; i < t.header.size(); ++i) out.emplace_back(t.header[i], to_double(t.rows.back()[i]));
  return out;
}
double get(const std::vector<std::pair<std::string, double>>& r, const std::string& k)
{
  for (auto& kv : r) if (kv.first == k) return kv.second;
  fail("missing column " + k);
}

// ---------------------------------------------------------------- final selection
int output_main(const std::string& c, const std::string& run, const std::string& aoff, const std::string& aon)
{
  auto a0 = last_row(run + "/out/native_off.csv"), a1 = last_row(run + "/out/native_on.csv");
  auto e0 = last_row(run + "/out/native_elec_off.csv"), e1 = last_row(run + "/out/native_elec_on.csv");
  J chk = json_load(run + "/out/check_on.json");
  auto ov = [](const std::string& a, bool& has) {
    for (const char* n : {"overlap_in_summary.json", "overlap_4cts_summary.json"})
      if (path_exists(join_path(a, n))) { has = true; return json_load(join_path(a, n)).get("overlaps_real").num(); }
    has = false;
    return 0.0;
  };
  // the LP-bound line is printed by stage D (flow/cts/cts_stage.sh) to the stage log of the run
  std::string txt;
  for (const char* f : {"on_D.log", "stages.log"}) if (path_exists(run + "/logs/" + f)) txt += read_text(run + "/logs/" + f);
  std::regex re(R"(LP bounds: (\d+) nodes, (\d+) zero \(early-group members (\d+)\))");
  std::vector<std::string> mb;
  for (std::sregex_iterator it(txt.begin(), txt.end(), re), end; it != end; ++it) mb = {(*it)[1].str(), (*it)[2].str(), (*it)[3].str()};
  std::vector<std::string> fails;
  bool hon, hoff;
  double ovon = ov(aon, hon), ovoff = ov(aoff, hoff);
  if (!hon || ovon != 0) fails.push_back("overlap");
  const J* pbc = chk.find("plan_bad_count");
  if (pbc && pbc->num() != 0) fails.push_back("plan_connectivity");
  if (mb.empty() || to_int(mb[1]) < to_int(mb[2])) fails.push_back("member_bound");
  for (const char* k : {"max_cap_violations", "max_fanout_violations", "max_slew_violations"}) if ((long long) get(e1, k) > (long long) get(e0, k)) fails.push_back(k);
  J d = J::Obj();
  for (auto& kv : a0) d.set(kv.first, J::D(get(a1, kv.first) - kv.second));
  double dt = d.get("setup_tns_ps").d + d.get("hold_tns_ps").d;
  if (!(dt > 1.0)) fails.push_back("tns_gain");
  J tol = J::Obj();
  for (const char* k : {"setup_wns_ps", "hold_wns_ps"}) tol.set(k, J::D(std::min(5.0, 0.01 * std::fabs(get(a0, k)))));
  for (auto& kv : tol.o) if (d.get(kv.first).d < -kv.second.d) fails.push_back(kv.first);
  J out = J::Obj();
  out.set("case", J::S(c)); out.set("decision", J::S(fails.empty() ? "accept" : "reject"));
  J fj = J::Arr();
  for (auto& f : fails) fj.push(J::S(f));
  out.set("fails", fj); out.set("d", d); out.set("d_tns_sum", J::D(dt)); out.set("wns_tol", tol);
  auto tojs = [](const std::vector<std::pair<std::string, double>>& r, bool asint) { J j = J::Obj(); for (auto& kv : r) j.set(kv.first, asint ? J::I((long long) kv.second) : J::D(kv.second)); return j; };
  out.set("OFF", tojs(a0, false)); out.set("ON", tojs(a1, false)); out.set("elec_OFF", tojs(e0, true)); out.set("elec_ON", tojs(e1, true));
  J ovj = J::Obj();
  ovj.set("off", hoff ? J::D(ovoff) : J::Null()); ovj.set("on", hon ? J::D(ovon) : J::Null());
  // overlaps_real is an integer count in the summary
  if (hoff) ovj.set("off", J::I((long long) ovoff));
  if (hon) ovj.set("on", J::I((long long) ovon));
  out.set("overlaps", ovj);
  if (mb.empty()) out.set("bounds", J::Null());
  else { J b = J::Arr(); for (auto& s : mb) b.push(J::S(s)); out.set("bounds", b); }
  write_text(run + "/out/select.json", out.dump(1));
  J pr = J::Obj();
  for (const char* k : {"case", "decision", "fails", "d_tns_sum"}) pr.set(k, out.get(k));
  std::printf("%s\n", pr.dump(0).c_str());
  return 0;
}

// ---------------------------------------------------------------- plan connectivity
struct Def
{
  std::vector<std::pair<std::string, std::string>> comp_order;   // name, master (file order)
  std::unordered_map<std::string, std::string> comp;
  std::vector<std::string> net_order;
  std::unordered_map<std::string, std::vector<std::pair<std::string, std::string>>> nets;   // net -> (inst, pin)
};
Def parse_def_nets(const std::string& f)
{
  Def D;
  std::ifstream in(f);
  if (!in) fail("cannot read " + f);
  std::string l;
  char sec = 0;
  std::vector<std::string> buf;
  std::regex re_name(R"(- (\S+))"), re_pin(R"(\( (\S+) (\S+) \))");
  while (std::getline(in, l)) {
    if (starts_with(l, "COMPONENTS")) { sec = 'C'; continue; }
    if (starts_with(l, "END COMPONENTS")) { sec = 0; continue; }
    if (starts_with(l, "NETS") || starts_with(l, "SPECIALNETS")) { sec = starts_with(l, "NETS") ? 'N' : 'S'; continue; }
    if (starts_with(l, "END NETS") || starts_with(l, "END SPECIALNETS")) { sec = 0; continue; }
    if (sec == 'C') {
      std::string t = l;
      size_t b = t.find_first_not_of(" \t");
      if (b != std::string::npos && t.compare(b, 2, "- ") == 0) {
        std::istringstream ss(t);
        std::string dash, name, master;
        ss >> dash >> name >> master;
        if (!D.comp.count(name)) D.comp_order.emplace_back(name, master);
        D.comp[name] = master;
      }
    } else if (sec == 'N') {
      buf.push_back(strip(l));
      std::string r = l;
      while (!r.empty() && std::isspace((unsigned char) r.back())) r.pop_back();
      if (!r.empty() && r.back() == ';') {
        std::string s;
        for (size_t i = 0; i < buf.size(); ++i) { if (i) s += ' '; s += buf[i]; }
        buf.clear();
        std::smatch m;
        if (std::regex_search(s, m, re_name) && m.position(0) == 0) {
          std::string head = s.substr(0, s.find(" + ") == std::string::npos ? s.size() : s.find(" + "));
          std::vector<std::pair<std::string, std::string>> pins;
          for (std::sregex_iterator it(head.begin(), head.end(), re_pin), end; it != end; ++it) pins.emplace_back((*it)[1].str(), (*it)[2].str());
          if (!D.nets.count(m[1].str())) D.net_order.push_back(m[1].str());
          D.nets[m[1].str()] = pins;
        }
      }
    }
  }
  return D;
}
struct Index
{
  std::unordered_map<std::string, std::string> drv;                                  // net -> driver inst
  std::vector<std::pair<std::pair<std::string, std::string>, std::string>> p2n_order; // (inst, pin) -> net, insertion order
  std::map<std::pair<std::string, std::string>, std::string> p2n;
  std::unordered_map<std::string, long> load;
};
const std::set<std::string> OUTP = {"Y", "Z", "Q", "QN", "ZN"};
Index index_of(const Def& D)
{
  Index I;
  for (auto& n : D.net_order) {
    auto& pins = D.nets.at(n);
    for (auto& ip : pins) {
      if (!I.p2n.count(ip)) I.p2n_order.emplace_back(ip, n);
      I.p2n[ip] = n;
      if (ip.first != "PIN" && OUTP.count(ip.second) && D.comp.count(ip.first)) I.drv[n] = ip.first;
    }
    I.load[n] = (long) pins.size();
  }
  return I;
}
std::string cls_of(const std::string& i)
{
  if (starts_with(i, "clkbuf_ghtap")) return "ladder (clkbuf_ghtap*)";
  if (starts_with(i, "clkbuf_early_") || starts_with(i, "clkbuf_hub_")) return "hub/early leaf";
  if (starts_with(i, "clkbuf_") || starts_with(i, "delaybuf") || starts_with(i, "clkload")) return "clock buffer (clkbuf_*/delaybuf)";
  return "other";
}
std::string drv_of(const Index& I, const std::string& net)
{
  auto it = I.drv.find(net);
  return it == I.drv.end() ? "" : it->second;
}
std::string re_escape(const std::string& s)
{
  std::string o;
  for (char c : s) { if (std::strchr(".^$|()[]{}*+?\\", c)) o += '\\'; o += c; }
  return o;
}

int plan_main(const std::vector<std::string>& a)
{
  const std::string cas = a.at(0), adef = a.at(1), rdef = a.at(2);
  std::string plan = a.size() > 3 && a[3] != "-" ? a[3] : "";
  std::string outj = a.size() > 4 ? a[4] : "";
  Def A = parse_def_nets(adef), Rf = parse_def_nets(rdef);
  Index da = index_of(A), dr = index_of(Rf);
  J res = J::Obj();
  res.set("case", J::S(cas)); res.set("arm_def", J::S(adef)); res.set("ref_def", J::S(rdef));
  if (!plan.empty()) {
    auto lines = read_lines(plan);
    J bad = J::Arr(), bypassed = J::Arr(), renamed = J::Arr();
    long rows = 0;
    for (size_t li = 1; li < lines.size(); ++li) {
      auto f = split(lines[li], '\t');
      if (f.size() < 8) continue;
      ++rows;
      const std::string& gid = f[0];
      const std::string& mode = f[1];
      const std::string& parent = f[5];
      const std::string& members = f[7];
      std::string L = mode == "new" ? "clkbuf_early_" + gid : f[6];
      std::string tier = split(parent, ':').at(2);
      std::regex ishub_re("^clkbuf_hub_.*_t" + tier + "(_rz\\d+)?$");
      auto ishub = [&](const std::string& d) { return std::regex_match(d, ishub_re); };
      std::set<std::string> hub_out;
      for (auto& kv : da.drv) if (ishub(kv.second)) hub_out.insert(kv.first);
      if (!A.comp.count(L)) {
        std::regex alt_re("^" + re_escape(L) + "_rz\\d+$");
        for (auto& c : A.comp_order) if (std::regex_match(c.first, alt_re)) { renamed.push(J::S(L + "->" + c.first)); L = c.first; break; }
      }
      if (!A.comp.count(L)) {
        bool all = true;
        for (auto& m : split(members, ';')) {
          auto sl = m.find('/');
          auto it = da.p2n.find({m.substr(0, sl), m.substr(sl + 1)});
          if (it == da.p2n.end() || !hub_out.count(it->second)) { all = false; break; }
        }
        if (all) { bypassed.push(J::S(gid)); continue; }
        J b = J::Arr(); b.push(J::S(gid)); b.push(J::S("leaf missing " + L)); bad.push(b);
        continue;
      }
      std::string out_net, in_net;
      bool has_out = false, has_in = false;
      for (auto& kv : da.p2n_order) {
        if (kv.first.first == L && OUTP.count(kv.first.second) && !has_out) { out_net = kv.second; has_out = true; }
        if (kv.first.first == L && kv.first.second == "A" && !has_in) { in_net = kv.second; has_in = true; }
      }
      std::string hub = has_in ? drv_of(da, in_net) : "";
      if (!ishub(hub)) { J b = J::Arr(); b.push(J::S(gid)); b.push(J::S("leaf input driver " + hub + " (net " + (has_in ? in_net : "None") + ")")); bad.push(b); }
      for (auto& m : split(members, ';')) {
        auto sl = m.find('/');
        auto it = da.p2n.find({m.substr(0, sl), m.substr(sl + 1)});
        bool onnet = it != da.p2n.end() && has_out && it->second == out_net;
        bool onhub = it != da.p2n.end() && hub_out.count(it->second);
        if (!onnet && !onhub) {
          std::string n = it == da.p2n.end() ? "None" : it->second;
          std::string dn = it == da.p2n.end() ? "None" : (da.drv.count(n) ? da.drv.at(n) : "None");
          J b = J::Arr(); b.push(J::S(gid)); b.push(J::S("member " + m + " on net " + n + " driven by " + dn)); bad.push(b);
        }
      }
    }
    res.set("plan_groups", J::I(rows));
    J bad50 = J::Arr();
    for (size_t i = 0; i < bad.a.size() && i < 50; ++i) bad50.push(bad.a[i]);
    res.set("plan_bad", bad50); res.set("plan_bad_count", J::I((long long) bad.a.size()));
    res.set("plan_leaf_bypassed_by_refinement", bypassed); res.set("plan_leaf_renamed_by_refinement_resize", renamed);
  }
  // 2. master changes
  std::vector<std::string> chg_order;
  std::map<std::string, std::vector<std::string>> chg;
  for (auto& c : A.comp_order) {
    auto r = Rf.comp.find(c.first);
    if (r != Rf.comp.end() && r->second != c.second) {
      std::string k = cls_of(c.first);
      if (!chg.count(k)) chg_order.push_back(k);
      chg[k].push_back(c.first + " " + r->second + "->" + c.second);
    }
  }
  J mc = J::Obj(), mce = J::Obj();
  for (auto& k : chg_order) {
    mc.set(k, J::I((long long) chg[k].size()));
    J ex = J::Arr();
    for (size_t i = 0; i < chg[k].size() && i < 8; ++i) ex.push(J::S(chg[k][i]));
    mce.set(k, ex);
  }
  res.set("master_changes", mc); res.set("master_change_examples", mce);
  auto added_removed = [&](const Def& X, const Def& Yd) {
    std::vector<std::string> only;
    for (auto& c : X.comp_order) if (!Yd.comp.count(c.first) && cls_of(c.first) != "other") only.push_back(c.first);
    J j = J::Obj();
    j.set("count", J::I((long long) only.size()));
    J bc = J::Obj();
    std::vector<std::string> korder;
    std::map<std::string, long long> cnt;
    for (auto& i : only) { std::string k = cls_of(i); if (!cnt.count(k)) korder.push_back(k); cnt[k]++; }
    for (auto& k : korder) bc.set(k, J::I(cnt[k]));
    j.set("by_class", bc);
    return j;
  };
  res.set("clock_insts_added", added_removed(A, Rf));
  res.set("clock_insts_removed", added_removed(Rf, A));
  // 3. register clock pins: driver changes
  std::vector<std::string> morder;
  std::map<std::string, long long> moved;
  long nreg = 0;
  for (auto& kv : da.p2n_order) {
    const std::string& i = kv.first.first;
    const std::string& p = kv.first.second;
    if ((p == "CLK" || p == "CK") && A.comp.count(i)) {
      ++nreg;
      std::string ad = drv_of(da, kv.second);
      auto rp = dr.p2n.find(kv.first);
      std::string rd = rp == dr.p2n.end() ? "" : drv_of(dr, rp->second);
      if (ad != rd) {
        std::string k = cls_of(rd.empty() ? "?" : rd) + " -> " + cls_of(ad.empty() ? "?" : ad);
        if (!moved.count(k)) morder.push_back(k);
        moved[k]++;
      }
    }
  }
  res.set("registers", J::I(nreg));
  J mv = J::Obj();
  for (auto& k : morder) mv.set(k, J::I(moved[k]));
  res.set("clock_pin_driver_changes", mv);
  std::vector<std::string> br;
  for (auto& n : A.net_order) {
    auto d = da.drv.find(n);
    if (d == da.drv.end()) continue;
    const std::string& dv = d->second;
    if (starts_with(dv, "clkbuf_") && !(starts_with(dv, "clkbuf_ghtap") || starts_with(dv, "clkbuf_early_") || starts_with(dv, "clkbuf_hub_") || starts_with(dv, "clkbuf_leaf"))
        && dr.load.count(n) && dr.load.at(n) != da.load.at(n))
      br.push_back(n + " (" + dv + "): " + std::to_string(dr.load.at(n)) + " -> " + std::to_string(da.load.at(n)) + " pins");
  }
  J brj = J::Arr();
  for (size_t i = 0; i < br.size() && i < 30; ++i) brj.push(J::S(br[i]));
  res.set("branch_net_pin_changes", brj); res.set("branch_net_pin_change_count", J::I((long long) br.size()));
  std::string s = res.dump(1);
  if (!outj.empty()) write_text(outj, s);
  std::printf("%s\n", s.c_str());
  return 0;
}

// ---------------------------------------------------------------- same-tier overlap check
const std::regex PHYS_NAME(R"((FILLER|FILL|TAPCELL|TAP_|WELLTAP|DECAP|ENDCAP|PHY_|ANTENNA))", std::regex::icase);
const std::regex SEQ_MASTER(R"((DFF|SDF|DHL|DLL|DLH|ICG|CLKGATE|LATCH|^DL|SRAM|fakeram))", std::regex::icase);
const std::regex CLK_NAME(R"(^(clkbuf|clkload|clkinv|delaybuf|sg_|cts_|clknet|clk_)|_clk$|relay|ghtap|dummy)", std::regex::icase);
const std::set<std::string> ORIENT_SWAP = {"E", "W", "FE", "FW", "R90", "R270", "MXR90", "MYR90"};
const char* PHYS_CLASSES[] = {"SPACER", "WELLTAP", "ENDCAP", "ANTENNACELL", "TAPCELL"};

struct Macro { double w, h; std::string cls, path; };
struct Comp { std::string master, status, orient; long long x = 0, y = 0; bool placed = false; };
struct Row { std::string name, site, orient; long long x, y, nx = 1, ny = 1, sx = 0, sy = 0; };
struct DefP { long long units = 1000; bool has_die = false; long long die[4] = {0, 0, 0, 0}; std::vector<Row> rows; std::vector<std::string> order; std::unordered_map<std::string, Comp> comps; };

std::string lower(std::string s) { for (auto& c : s) c = (char) std::tolower((unsigned char) c); return s; }

std::unordered_map<std::string, Macro> parse_lefs(std::vector<std::string> paths, long& conflicts)
{
  // cover LEFs first, then by path; a later (real) definition wins
  std::stable_sort(paths.begin(), paths.end(), [](const std::string& a, const std::string& b) {
    bool ca = lower(basename_of(a)).find("cover") == std::string::npos, cb = lower(basename_of(b)).find("cover") == std::string::npos;
    if (ca != cb) return ca < cb;
    return a < b;
  });
  std::unordered_map<std::string, Macro> macros;
  conflicts = 0;
  for (auto& p : paths) {
    std::ifstream in(p);
    if (!in) fail("cannot read " + p);
    std::string line, cur, cls;
    bool has_size = false;
    double sw = 0, sh = 0;
    while (std::getline(in, line)) {
      std::istringstream ss(line);
      std::vector<std::string> t;
      std::string w;
      while (ss >> w) t.push_back(w);
      if (t.empty()) continue;
      if (t[0] == "MACRO" && t.size() > 1) { cur = t[1]; cls.clear(); has_size = false; }
      else if (!cur.empty() && t[0] == "CLASS") { cls.clear(); for (size_t i = 1; i < t.size(); ++i) if (t[i] != ";") { if (!cls.empty()) cls += " "; cls += t[i]; } }
      else if (!cur.empty() && t[0] == "SIZE" && t.size() >= 4) { sw = to_double(t[1]); sh = to_double(t[3]); has_size = true; }
      else if (!cur.empty() && t[0] == "END" && t.size() > 1 && t[1] == cur) {
        if (has_size) {
          auto old = macros.find(cur);
          if (old != macros.end() && (std::fabs(old->second.w - sw) > 1e-6 || std::fabs(old->second.h - sh) > 1e-6)) ++conflicts;
          macros[cur] = {sw, sh, cls, p};
        }
        cur.clear();
      }
    }
  }
  return macros;
}

DefP parse_def(const std::string& path, bool want_rows)
{
  DefP D;
  std::ifstream in(path);
  if (!in) fail("cannot read " + path);
  std::string line;
  std::regex re_int(R"(-?\d+)");
  while (std::getline(in, line)) {
    std::string s = strip(line);
    if (starts_with(s, "UNITS DISTANCE MICRONS")) { std::istringstream ss(s); std::string a, b, c, d; ss >> a >> b >> c >> d; D.units = to_int(d); }
    else if (starts_with(s, "DIEAREA")) {
      std::vector<long long> nums;
      for (std::sregex_iterator it(s.begin(), s.end(), re_int), end; it != end; ++it) nums.push_back(to_int((*it)[0].str()));
      long long xmin = nums[0], xmax = nums[0], ymin = nums[1], ymax = nums[1];
      for (size_t i = 0; i + 1 < nums.size(); i += 2) { xmin = std::min(xmin, nums[i]); xmax = std::max(xmax, nums[i]); ymin = std::min(ymin, nums[i + 1]); ymax = std::max(ymax, nums[i + 1]); }
      D.die[0] = xmin; D.die[1] = ymin; D.die[2] = xmax; D.die[3] = ymax; D.has_die = true;
    } else if (starts_with(s, "ROW ") && want_rows) {
      std::istringstream ss(s);
      std::vector<std::string> t;
      std::string w;
      while (ss >> w) t.push_back(w);
      Row r{t[1], t[2], t[5], to_int(t[3]), to_int(t[4])};
      for (size_t i = 0; i < t.size(); ++i) {
        if (t[i] == "DO" && i + 3 < t.size()) { r.nx = to_int(t[i + 1]); r.ny = to_int(t[i + 3]); }
        if (t[i] == "STEP" && i + 2 < t.size()) { r.sx = to_int(t[i + 1]); r.sy = to_int(t[i + 2]); }
      }
      D.rows.push_back(r);
    } else if (starts_with(s, "COMPONENTS")) {
      std::string buf;
      while (std::getline(in, line)) {
        std::string s2 = strip(line);
        if (starts_with(s2, "END COMPONENTS")) break;
        buf += " " + s2;
        if (s2.empty() || s2.back() != ';') continue;
        std::istringstream ss(buf);
        std::vector<std::string> t;
        std::string w;
        while (ss >> w) t.push_back(w);
        buf.clear();
        if (t.size() < 3 || t[0] != "-") continue;
        Comp c;
        c.master = t[2]; c.status = "UNPLACED"; c.orient = "N";
        for (const char* st : {"PLACED", "FIXED", "COVER"}) {
          auto it = std::find(t.begin(), t.end(), st);
          if (it != t.end()) { size_t i = it - t.begin(); c.status = st; c.x = to_int(t[i + 2]); c.y = to_int(t[i + 3]); c.orient = t[i + 5]; c.placed = true; break; }
        }
        if (!D.comps.count(t[1])) D.order.push_back(t[1]);
        D.comps[t[1]] = c;
      }
      break;
    }
  }
  return D;
}

int tier_of(const std::string& m) { return ends_with(m, "_bottom") ? 0 : (ends_with(m, "_upper") ? 1 : -1); }

std::string role_of(const std::string& name, const std::string& master, const std::string& mclass, const std::set<std::string>* clock_set)
{
  std::string c = mclass;
  for (auto& ch : c) ch = (char) std::toupper((unsigned char) ch);
  if (starts_with(c, "BLOCK") || starts_with(c, "RING") || starts_with(c, "PAD")) return "macro";
  bool phys = false;
  for (const char* k : PHYS_CLASSES) if (c.find(k) != std::string::npos) phys = true;
  if (phys || std::regex_search(master, PHYS_NAME) || starts_with(c, "COVER")) { if (!std::regex_search(master, SEQ_MASTER)) return "physonly"; }
  if ((clock_set && clock_set->count(name)) || (!clock_set && std::regex_search(name, CLK_NAME))) return "clock";
  if (std::regex_search(master, SEQ_MASTER)) return "seq";
  return "logic";
}

struct Cell { long idx; long long x0, y0, x1, y1; };
struct Ov { long long area, dx, dy; };
std::map<std::pair<long, long>, Ov> find_overlaps(const std::vector<Cell>& cells, long long bin)
{
  std::map<std::pair<long long, long long>, std::vector<Cell>> grid;
  std::vector<std::pair<long long, long long>> gorder;
  for (auto& c : cells)
    for (long long bx = py_floordiv(c.x0, bin); bx <= py_floordiv(c.x1 - 1, bin); ++bx)
      for (long long by = py_floordiv(c.y0, bin); by <= py_floordiv(c.y1 - 1, bin); ++by) {
        if (!grid.count({bx, by})) gorder.emplace_back(bx, by);
        grid[{bx, by}].push_back(c);
      }
  std::map<std::pair<long, long>, Ov> out;
  for (auto& g : gorder) {
    auto& lst = grid[g];
    if (lst.size() < 2) continue;
    std::stable_sort(lst.begin(), lst.end(), [](const Cell& a, const Cell& b) { return a.x0 < b.x0; });
    for (size_t a = 0; a < lst.size(); ++a)
      for (size_t b = a + 1; b < lst.size(); ++b) {
        if (lst[b].x0 >= lst[a].x1) break;
        long long dx = std::min(lst[a].x1, lst[b].x1) - std::max(lst[a].x0, lst[b].x0), dy = std::min(lst[a].y1, lst[b].y1) - std::max(lst[a].y0, lst[b].y0);
        if (dx > 0 && dy > 0) out[{std::min(lst[a].idx, lst[b].idx), std::max(lst[a].idx, lst[b].idx)}] = {dx * dy, dx, dy};
      }
  }
  return out;
}

int overlap_main(const std::vector<std::string>& args)
{
  std::string deff, ref, clock_list, ng45, out;
  std::vector<std::string> lefdirs;
  long long bin = 3000;
  for (size_t i = 0; i < args.size(); ++i) {
    const std::string& a = args[i];
    auto val = [&]() { if (i + 1 >= args.size()) fail("missing value for " + a); return args[++i]; };
    if (a == "--def") deff = val(); else if (a == "--lefdir") lefdirs.push_back(val()); else if (a == "--ref") ref = val();
    else if (a == "--clock-list") clock_list = val(); else if (a == "--ng45-grid") ng45 = val(); else if (a == "--out") out = val();
    else if (a == "--bin") bin = to_int(val()); else fail("unknown option " + a);
  }
  if (deff.empty() || lefdirs.empty() || out.empty()) fail("overlap: --def, --lefdir and --out are required");
  std::vector<std::string> lefs;
  for (auto& d : lefdirs) {
    std::vector<std::string> files;
    walk_files(d, files);
    for (auto& p : files) {
      if (!ends_with(p, ".lef")) continue;
      if (p.find("/test/") != std::string::npos || p.find("lef_original") != std::string::npos || p.find("pitch_variant") != std::string::npos) continue;
      lefs.push_back(p);
    }
  }
  long conflicts = 0;
  auto macros = parse_lefs(lefs, conflicts);
  DefP D = parse_def(deff, true);
  long long units = D.units;
  std::unordered_map<std::string, Comp> refc;
  bool has_ref = !ref.empty();
  if (has_ref) refc = parse_def(ref, false).comps;
  std::set<std::string> cset;
  bool has_cset = false;
  if (!clock_list.empty() && path_exists(clock_list)) { has_cset = true; for (auto& l : read_lines(clock_list)) { std::string s = strip(l); if (!s.empty()) cset.insert(s); } }
  struct Info { std::string name, master, status, orient, role, mclass; int tier; bool has_bb; long long bb[4]; bool isnew, moved; };
  std::vector<Info> info;
  std::vector<std::string> mm_order;
  std::map<std::string, long> missing_master;
  long tier_unknown = 0, unplaced = 0;
  for (auto& n : D.order) {
    const Comp& c = D.comps[n];
    auto m = macros.find(c.master);
    if (m == macros.end()) { if (!missing_master.count(c.master)) mm_order.push_back(c.master); missing_master[c.master]++; }
    Info x;
    x.name = n; x.master = c.master; x.status = c.status; x.orient = c.orient; x.tier = tier_of(c.master);
    tier_unknown += x.tier < 0;
    x.has_bb = m != macros.end() && c.placed;
    if (x.has_bb) {
      long long w = (long long) std::nearbyint(m->second.w * (double) units), h = (long long) std::nearbyint(m->second.h * (double) units);
      if (ORIENT_SWAP.count(c.orient)) std::swap(w, h);
      x.bb[0] = c.x; x.bb[1] = c.y; x.bb[2] = c.x + w; x.bb[3] = c.y + h;
    } else ++unplaced;
    x.mclass = m != macros.end() ? m->second.cls : "?";
    x.role = role_of(n, c.master, m != macros.end() ? m->second.cls : "", has_cset ? &cset : nullptr);
    x.isnew = has_ref && !refc.count(n);
    x.moved = has_ref && !x.isnew && (refc[n].x != c.x || refc[n].y != c.y || refc[n].placed != c.placed);
    info.push_back(x);
  }
  struct Pair { int tier; const Info* A; const Info* B; long long dx, dy; double area; bool real; };
  std::vector<Pair> pairs;
  for (int tier : {0, 1, -1}) {
    std::vector<Cell> cells;
    for (size_t i = 0; i < info.size(); ++i) if (info[i].tier == tier && info[i].has_bb) cells.push_back({(long) i, info[i].bb[0], info[i].bb[1], info[i].bb[2], info[i].bb[3]});
    auto ov = find_overlaps(cells, bin);
    for (auto& kv : ov) {
      const Info& A = info[kv.first.first];
      const Info& B = info[kv.first.second];
      pairs.push_back({tier, &A, &B, kv.second.dx, kv.second.dy, (double) kv.second.area / (double) units / (double) units, !(A.role == "physonly" && B.role == "physonly")});
    }
  }
  std::stable_sort(pairs.begin(), pairs.end(), [](const Pair& a, const Pair& b) { return -a.area < -b.area; });
  // row / site / core checks
  std::map<long long, std::vector<const Row*>> rowmap;
  for (auto& r : D.rows) for (long long k = 0; k < r.ny; ++k) rowmap[r.y + k * r.sy].push_back(&r);
  long long core[4] = {0, 0, 0, 0};
  bool has_core = false;
  if (!D.rows.empty()) {
    core[0] = D.rows[0].x; core[1] = D.rows[0].y; core[2] = D.rows[0].x + D.rows[0].nx * std::max<long long>(D.rows[0].sx, 1); core[3] = D.rows[0].y;
    for (auto& r : D.rows) { core[0] = std::min(core[0], r.x); core[1] = std::min(core[1], r.y); core[2] = std::max(core[2], r.x + r.nx * std::max<long long>(r.sx, 1)); core[3] = std::max(core[3], r.y); }
    has_core = true;
  } else if (D.has_die) { for (int i = 0; i < 4; ++i) core[i] = D.die[i]; has_core = true; }
  struct Off { const Info* x; std::string problem; };
  std::vector<Off> off;
  std::vector<long long> ng;
  if (!ng45.empty()) for (auto& v : split(ng45, ',')) ng.push_back(to_int(v));
  auto bbstr = [](const long long* bb) { return std::to_string(bb[0]) + " " + std::to_string(bb[1]) + " " + std::to_string(bb[2]) + " " + std::to_string(bb[3]); };
  for (auto& x : info) {
    if (!x.has_bb || x.role == "macro") {
      if (x.has_bb && D.has_die && (x.bb[0] < D.die[0] || x.bb[1] < D.die[1] || x.bb[2] > D.die[2] || x.bb[3] > D.die[3])) off.push_back({&x, "outside_die"});
      continue;
    }
    long long x0 = x.bb[0], y0 = x.bb[1], x1 = x.bb[2], y1 = x.bb[3];
    std::vector<std::string> prob;
    bool hetero_bottom = !ng.empty() && x.tier == 0;
    if (hetero_bottom) {
      if ((x0 - ng[2]) % ng[0] || (y0 - ng[3]) % ng[1]) prob.push_back("off_ng45_grid");
    } else {
      auto rl = rowmap.find(y0);
      if (rl == rowmap.end()) prob.push_back("off_row");
      else {
        const Row* inside = nullptr;
        for (auto* r : rl->second) if (x0 >= r->x && x1 <= r->x + r->nx * std::max<long long>(r->sx, 1)) { inside = r; break; }
        if (!inside) prob.push_back("outside_row_span");
        else if (inside->sx && (x0 - inside->x) % inside->sx) prob.push_back("off_site");
      }
    }
    if (D.has_die && (x0 < D.die[0] || y0 < D.die[1] || x1 > D.die[2] || y1 > D.die[3])) prob.push_back("outside_die");
    if (!D.rows.empty() && !hetero_bottom && has_core && (x0 < core[0] || y0 < core[1] || y0 > core[3])) prob.push_back("outside_core");
    for (auto& p : prob) off.push_back({&x, p});
  }
  mkdirs(dirname_of(out));
  {
    std::string s = csv_row({"tier", "a", "a_master", "a_role", "a_new", "a_moved", "a_status", "a_bbox", "b", "b_master", "b_role", "b_new", "b_moved", "b_status", "b_bbox", "dx_dbu", "dy_dbu", "area_um2", "kind"});
    for (auto& p : pairs)
      s += csv_row({std::to_string(p.tier), p.A->name, p.A->master, p.A->role, p.A->isnew ? "1" : "0", p.A->moved ? "1" : "0", p.A->status, bbstr(p.A->bb), p.B->name, p.B->master, p.B->role,
                    p.B->isnew ? "1" : "0", p.B->moved ? "1" : "0", p.B->status, bbstr(p.B->bb), std::to_string(p.dx), std::to_string(p.dy), py_repr(p.area), p.real ? "real" : "intended"});
    write_text(out + "_overlaps.csv", s);
  }
  {
    std::string s = csv_row({"name", "master", "role", "tier", "new", "problem", "bbox"});
    for (auto& o : off) s += csv_row({o.x->name, o.x->master, o.x->role, std::to_string(o.x->tier), o.x->isnew ? "1" : "0", o.problem, bbstr(o.x->bb)});
    write_text(out + "_offgrid.csv", s);
  }
  std::vector<const Pair*> real;
  for (auto& p : pairs) if (p.real) real.push_back(&p);
  auto counter = [](const std::vector<std::string>& keys) {
    J j = J::Obj();
    std::vector<std::string> order;
    std::map<std::string, long long> c;
    for (auto& k : keys) { if (!c.count(k)) order.push_back(k); c[k]++; }
    for (auto& k : order) j.set(k, J::I(c[k]));
    return j;
  };
  std::vector<std::string> pr, age, bytier, offp, offn, offr;
  for (auto* p : real) {
    std::vector<std::string> rr{p->A->role, p->B->role};
    std::sort(rr.begin(), rr.end());
    pr.push_back(rr[0] + "-" + rr[1]);
    int n = (p->A->isnew ? 1 : 0) + (p->B->isnew ? 1 : 0);
    age.push_back(n == 0 ? "old-old" : (n == 1 ? "new-old" : "new-new"));
    bytier.push_back(std::to_string(p->tier));
  }
  for (auto& o : off) { offp.push_back(o.problem); if (o.x->isnew) offn.push_back(o.problem); offr.push_back(o.x->role + ":" + o.problem); }
  double real_area = 0.0;
  { bool first = true; for (auto* p : real) { if (first) { real_area = p->area; first = false; } else real_area += p->area; } }
  long n_new = 0, n_moved = 0, clock_cells = 0, real_clock = 0, real_new = 0;
  for (auto& x : info) { n_new += x.isnew; n_moved += x.moved; clock_cells += x.role == "clock"; }
  for (auto* p : real) { real_clock += (p->A->role == "clock" || p->B->role == "clock"); real_new += (p->A->isnew || p->B->isnew); }
  J S = J::Obj();
  S.set("def_", J::S(deff)); S.set("ref", has_ref ? J::S(ref) : J::Null()); S.set("units", J::I(units)); S.set("n_cells", J::I((long long) info.size()));
  S.set("n_new", J::I(n_new)); S.set("n_moved_old", J::I(n_moved)); S.set("tier_unknown", J::I(tier_unknown)); S.set("unplaced", J::I(unplaced));
  J mmj = J::Obj();
  for (auto& k : mm_order) mmj.set(k, J::I(missing_master[k]));
  S.set("missing_masters", mmj); S.set("lef_size_conflicts", J::I(conflicts));
  S.set("clock_set", J::S(has_cset ? "sta" : "name_rule")); S.set("clock_cells", J::I(clock_cells));
  S.set("overlaps_total", J::I((long long) pairs.size())); S.set("overlaps_real", J::I((long long) real.size()));
  S.set("overlaps_intended", J::I((long long) (pairs.size() - real.size()))); S.set("real_area_um2", J::D(py_round(real_area, 6)));
  S.set("real_by_roles", counter(pr)); S.set("real_by_age", counter(age)); S.set("real_by_tier", counter(bytier));
  S.set("real_involving_clock", J::I(real_clock)); S.set("real_involving_new", J::I(real_new));
  S.set("offgrid", counter(offp)); S.set("offgrid_new", counter(offn)); S.set("offgrid_by_role", counter(offr));
  write_text(out + "_summary.json", S.dump(1) + "\n");
  J pj = J::Obj();
  for (const char* k : {"n_cells", "n_new", "overlaps_real", "real_by_roles", "real_by_age", "offgrid", "missing_masters"}) pj.set(k, S.get(k));
  std::printf("%s\n", pj.dump(0).c_str());
  return 0;
}

// ---------------------------------------------------------------- case report
// absolute, normalized path (".", ".." and repeated "/" removed; symlinks not resolved)
std::string abspath_norm(const std::string& p)
{
  std::string full = p;
  if (full.empty() || full[0] != '/') { char cwd[PATH_MAX]; if (!::getcwd(cwd, sizeof cwd)) fail("getcwd"); full = std::string(cwd) + "/" + full; }
  std::vector<std::string> parts;
  for (auto& c : split(full, '/')) { if (c.empty() || c == ".") continue; if (c == "..") { if (!parts.empty()) parts.pop_back(); continue; } parts.push_back(c); }
  std::string o;
  for (auto& c : parts) o += "/" + c;
  return o.empty() ? "/" : o;
}
// path relative to start (both normalized as above)
std::string relpath(const std::string& path, const std::string& start)
{
  auto a = split(abspath_norm(path), '/'), b = split(abspath_norm(start), '/');
  size_t i = 0;
  while (i < a.size() && i < b.size() && a[i] == b[i]) ++i;
  std::string o;
  for (size_t k = i; k < b.size(); ++k) if (!b[k].empty()) o += "../";
  for (size_t k = i; k < a.size(); ++k) { if (a[k].empty()) continue; o += a[k]; if (k + 1 < a.size()) o += "/"; }
  if (o.empty()) o = ".";
  if (o.size() > 1 && o.back() == '/') o.pop_back();
  return o;
}

int report_main(const std::vector<std::string>& a)
{
  const std::string run = a.at(0), cas = a.at(1), out_arm = a.at(2), arm_dir = a.at(3), why = a.at(4);
  std::string plan = a.size() > 5 ? a[5] : "";
  std::string O = join_path(run, "out");   // diagnostic tables stay in the work directory; results/ holds the checkpoint
  auto metrics = [](const std::string& path, std::vector<double>& m) {
    if (!path_exists(path)) return false;
    auto r = last_row(path);
    m = {get(r, "setup_tns_ps"), get(r, "setup_wns_ps"), get(r, "hold_tns_ps"), get(r, "hold_wns_ps")};
    return true;
  };
  struct Arm { std::string name, dir, nat; };
  std::vector<Arm> arms{{"OFF", join_path(run, "arms/off"), join_path(run, "out/native_off.csv")}, {"ON", join_path(run, "arms/on"), join_path(run, "out/native_on.csv")}};
  std::string mh = join_path(run, "multi_hub");
  if (is_dir(mh)) {
    std::regex kre(R"(k\d+)");
    for (auto& d : list_dir(mh)) if (std::regex_match(d, kre)) arms.push_back({"ON multi-hub " + d, join_path(mh, d + "/arms/on"), join_path(mh, d + "/out/native_on.csv")});
  }
  std::string timing = "# case " + cas + ": CTS checkpoint timing (ps).  \"checkpoint\" = STA of the final CTS checkpoint of the arm in the\n"
                       "# relocation session (placement parasitics); \"reload\" = independent STA reload of the route input of the\n"
                       "# arm (placement parasitics; used by the ON/OFF selection).\n";
  char buf[512];
  std::snprintf(buf, sizeof buf, "%-22s %-10s %14s %12s %14s %12s\n", "arm", "source", "setup_TNS", "setup_WNS", "hold_TNS", "hold_WNS");
  timing += buf;
  auto line = [&](const std::string& name, const char* src, const std::vector<double>& m) {
    std::snprintf(buf, sizeof buf, "%-22s %-10s %14.1f %12.2f %14.1f %12.2f\n", name.c_str(), src, m[0], m[1], m[2], m[3]);
    return std::string(buf);
  };
  for (auto& ar : arms) {
    std::vector<double> m, n;
    if (!metrics(join_path(ar.dir, "final/metrics.csv"), m)) continue;
    timing += line(ar.name, "checkpoint", m);
    if (metrics(ar.nat, n)) timing += line(ar.name, "reload", n);
  }
  std::vector<double> chosen;
  if (metrics(join_path(arm_dir, "final/metrics.csv"), chosen)) {
    std::string up = out_arm;
    for (auto& c : up) c = (char) std::toupper((unsigned char) c);
    timing += line("OUTPUT (" + up + ")", "checkpoint", chosen);
  }
  write_text(join_path(O, "timing.txt"), timing);
  std::string pol = "case            " + cas + "\n";
  pol += "output          " + std::string(out_arm == "off" ? "OFF (no early clock structure)" : out_arm == "on" ? "ON (early clock structure)" : "ON (multi-hub plan " + out_arm + ")") + "\n";
  pol += "reason          " + why + "\n";
  pol += "output arm      " + relpath(arm_dir, run) + "\n";
  pol += "early plan      " + (plan.empty() ? std::string("-") : relpath(plan, run)) + "\n";
  auto js = [](const J& j, const char* k) {
    const J* v = j.find(k);
    if (!v) return std::string("None");
    if (v->t == J::STR) return v->s;
    if (v->t == J::INT) return std::to_string(v->i);
    if (v->t == J::DBL) return py_repr(v->d);
    if (v->t == J::BOOL) return std::string(v->b ? "True" : "False");
    if (v->t == J::NUL) return std::string("None");
    if (v->t == J::ARR) { std::vector<std::string> xs; for (auto& e : v->a) xs.push_back(e.s); return py_list_repr(xs); }
    return std::string("?");
  };
  std::string eg = join_path(run, "decide/early_groups/summary.json");
  if (path_exists(eg)) { J s = json_load(eg); pol += "early groups    status=" + js(s, "status") + " selected=" + js(s, "selected") + " advanced_registers=" + js(s, "advanced_registers") + "\n"; }
  std::string hs = join_path(run, "decide/hub/plan/select.json");
  if (path_exists(hs)) { J s = json_load(hs); pol += "hub candidates  passing=" + js(s, "n_pass") + " selected=" + js(s, "selected") + "\n"; }
  std::string sel = join_path(run, "out/select.json");
  if (path_exists(sel)) {
    J s = json_load(sel);
    std::snprintf(buf, sizeof buf, "%.1f", s.get("d_tns_sum").num());
    pol += "selection (ON)  " + s.get("decision").s + " fails=" + js(s, "fails") + " d_tns_sum_ps=" + buf + "\n";
  }
  std::string mj = join_path(mh, "multi_hub.json");
  if (path_exists(mj)) {
    J s = json_load(mj);
    for (auto& r : s.get("prefixes").a) pol += "multi-hub k=" + std::to_string(r.get("k").i) + "   " + r.get("decision").s + " fails=" + js(r, "fails") + " d_tns_sum_ps=" + js(r, "d_tns_sum") + "\n";
    pol += "multi-hub       output " + s.get("output").s + "\n";
  }
  write_text(join_path(O, "POLICY.txt"), pol);
  return 0;
}

// ---------------------------------------------------------------- multi-hub verdict
int multihub_main(const std::vector<std::string>& a)
{
  const std::string cas = a.at(0), outf = a.at(1);
  J rows = J::Arr();
  struct Acc { long long k; double d; std::string arm; };
  std::vector<Acc> acc;
  for (size_t i = 2; i < a.size(); ++i) {
    std::istringstream ss(a[i]);
    std::string k, sel, arm;
    ss >> k >> sel >> arm;
    J s = json_load(sel);
    J r = J::Obj();
    r.set("k", J::I(to_int(k))); r.set("decision", s.get("decision"));
    r.set("fails", s.find("fails") ? *s.find("fails") : J::Null()); r.set("d_tns_sum", s.find("d_tns_sum") ? *s.find("d_tns_sum") : J::Null()); r.set("arm", J::S(arm));
    rows.push(r);
    if (s.get("decision").s == "accept") acc.push_back({to_int(k), s.get("d_tns_sum").num(), arm});
  }
  const Acc* best = nullptr;
  for (auto& x : acc) if (!best || x.d > best->d) best = &x;
  J out = J::Obj();
  out.set("case", J::S(cas)); out.set("prefixes", rows);
  out.set("output", J::S(best ? "on k=" + std::to_string(best->k) : "off")); out.set("arm", best ? J::S(best->arm) : J::Null());
  write_text(outf, out.dump(1));
  std::printf("%s\n", rows.dump(0).c_str());
  return 0;
}

// ---------------------------------------------------------------- ON-benefit gate (default; CTS3D_ON_GATE=1)
// Decides, from the early-clock decision files only (no STA, no CTS), whether building the single ON arm is
// worthwhile relative to OFF.  Inputs: <decide>/DECISION.txt; for an early-group plan <decide>/early_groups/summary.json
// (base / final = replay of the Phase-1 timing graph before / after the selected groups); for a hub plan the
// selected row of <decide>/hub/measured.csv (meas_gain, d_setup_wns) and <decide>/hub/gen.json (base).
//   B      = predicted setup + hold TNS gain (ps);  rel = B / (|base setup TNS| + |base hold TNS|)
//   risk   = predicted setup WNS loss (ps, >= 0);   tol = min(5 ps, 1 % |base setup WNS|) (same form as the output check)
// Skip ON when the benefit is negligible (rel < CTS3D_GATE_MIN_REL, default 0.5 %) or when the predicted setup WNS
// loss exceeds the tolerance even if only CTS3D_GATE_RHO of it is realised (default 0.5).  Anything not covered
// builds ON.
int gate_main(const std::vector<std::string>& a)
{
  const auto t0 = std::chrono::steady_clock::now();
  const std::string cas = a.at(0), dec = a.at(1), outf = a.at(2);
  const char* e1 = std::getenv("CTS3D_GATE_MIN_REL");
  const char* e2 = std::getenv("CTS3D_GATE_RHO");
  const double min_rel = e1 && *e1 ? to_double(e1) : 0.005, rho = e2 && *e2 ? to_double(e2) : 0.5;
  std::map<std::string, std::string> d;
  for (auto& l : split(read_text(dec + "/DECISION.txt"), '\n')) {
    auto p = l.find('=');
    if (p != std::string::npos) d[l.substr(0, p)] = l.substr(p + 1);
  }
  std::string kind = "none";
  double B = 0, dS = 0, bst = 0, bht = 0, bsw = 0;
  if (d["early_groups_status"] == "selected") {
    J s = json_load(dec + "/early_groups/summary.json");
    const J& b = s.get("base"); const J& f = s.get("final");
    kind = "groups";
    bst = b.get("st").num(); bht = b.get("ht").num(); bsw = b.get("sw").num();
    B = (f.get("st").num() - bst) + (f.get("ht").num() - bht);
    dS = f.get("sw").num() - bsw;
  } else if (!d["hub_cid"].empty()) {
    Table t = read_table(dec + "/hub/measured.csv");
    auto col = [&](const std::string& k) { for (size_t i = 0; i < t.header.size(); ++i) if (t.header[i] == k) return i; fail("missing column " + k); };
    const size_t ci = col("cid"), cg = col("meas_gain"), cs = col("d_setup_wns");
    for (auto& r : t.rows) if (r[ci] == d["hub_cid"]) { B = to_double(r[cg]); dS = to_double(r[cs]); kind = "hub"; }
    if (kind != "hub") fail("hub " + d["hub_cid"] + " not in measured.csv");
    J g = json_load(dec + "/hub/gen.json");
    const J& b = g.get("base");
    bst = b.get("st").num(); bht = b.get("ht").num(); bsw = b.get("sw").num();
  }
  const double denom = std::fabs(bst) + std::fabs(bht), rel = denom > 0 ? B / denom : 0;
  const double risk = std::max(0.0, -dS), tol = std::min(5.0, 0.01 * std::fabs(bsw));
  std::string decision = "build", why = "predicted benefit and setup WNS risk acceptable";
  if (kind == "none") { decision = "none"; why = "no early-clock plan"; }
  else if (rel < min_rel) { decision = "skip"; why = "predicted benefit negligible"; }
  else if (rho * risk > tol) { decision = "skip"; why = "predicted setup WNS loss beyond tolerance"; }
  const double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
  J o = J::Obj();
  o.set("case", J::S(cas)); o.set("kind", J::S(kind)); o.set("decision", J::S(decision)); o.set("reason", J::S(why));
  o.set("pred_tns_gain_ps", J::D(B)); o.set("pred_rel_gain", J::D(rel)); o.set("pred_setup_wns_change_ps", J::D(dS));
  o.set("tol_ps", J::D(tol)); o.set("rho", J::D(rho)); o.set("min_rel", J::D(min_rel)); o.set("elapsed_us", J::D(us));
  write_text(outf, o.dump(1));
  std::printf("%s rel=%.4f dS=%.2f tol=%.2f %s (%.0f us)\n", decision.c_str(), rel, dS, tol, why.c_str(), us);
  return 0;
}

int jget_main(const std::string& file, const std::string& key)
{
  J j = json_load(file);
  const J* v = j.find(key);
  if (!v) fail("key " + key + " not in " + file);
  switch (v->t) {
    case J::STR: std::printf("%s\n", v->s.c_str()); break;
    case J::INT: std::printf("%lld\n", v->i); break;
    case J::DBL: std::printf("%s\n", py_repr(v->d).c_str()); break;
    case J::BOOL: std::printf("%s\n", v->b ? "True" : "False"); break;
    case J::NUL: std::printf("None\n"); break;
    default: std::printf("%s\n", v->dump(0).c_str());
  }
  return 0;
}
}  // namespace

int main(int argc, char** argv)
{
  try {
    std::string cmd = argc > 1 ? argv[1] : "";
    std::vector<std::string> a;
    for (int i = 2; i < argc; ++i) a.push_back(argv[i]);
    if (cmd == "output" && a.size() == 4) return output_main(a[0], a[1], a[2], a[3]);
    if (cmd == "plan" && a.size() >= 3) return plan_main(a);
    if (cmd == "overlap") return overlap_main(a);
    if (cmd == "report" && a.size() >= 5) return report_main(a);
    if (cmd == "multihub" && a.size() >= 2) return multihub_main(a);
    if (cmd == "jget" && a.size() == 2) return jget_main(a[0], a[1]);
    if (cmd == "gate" && a.size() == 3) return gate_main(a);
    std::fprintf(stderr, "usage: cts_select output|plan|overlap|report|multihub|jget|gate ...\n");
    return 2;
  } catch (std::exception& e) {
    std::fprintf(stderr, "cts_select: %s\n", e.what());
    return 1;
  }
}
