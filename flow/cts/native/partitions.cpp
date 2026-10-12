// Partitioned timing-graph extraction: integrity check of the K partition outputs and their merge.
//
//   cts_partitions check <G_dir> <K> <run_token_file>          exit 0 = ok
//   cts_partitions merge <parts_dir> <K> <out_results_dir>
//
// Merge rules (nothing is recomputed from timing data; rows and events are copied as bytes):
//   FF graph   : header, then for launches in single-process order ("order" column of the index) that launch's
//                FF->FF rows, then one identity row per launch in the same order.
//   FF events  : header, then each launch's event bytes in single-process order.
//   FF status  : retained / unsupported / inactive_source_modes = sums over partitions; BLOCKED iff unsupported != 0.
//   IO events  : header, PI-side events (partition 0, or in queue mode the partition whose IO index says pi=1), then
//                each launch's FF->PO events in single-process order.
//   IO edges   : the single-process file is the iteration order of an unordered_map whose keys were inserted PI side
//                first, then per launch in single-process order.  The same key insertion sequence into a
//                std::unordered_map<std::string, int> (libstdc++ of the openroad binary, gcc 12) gives the same
//                iteration order, so this tool must be built with that compiler.
//   IO status  : retained / unsupported = sums; BLOCKED iff unsupported is non-zero.
// Static mode (EXTRACT_PARTITION only): partition k ran a fixed subset of the launches.  Queue mode (index headers
// with queue=1): the processes took chunks of launches from one shared counter, so any process may hold any launch
// and exactly one process ran the input-port side (pi=1); all partitions must agree on the mode and the chunk size.
// The merge itself is the same in both modes because it orders by the single-process launch order of every launch.
// Every structural assumption is checked; any violation aborts with exit status 3.
#include <chrono>
#include <cstdio>
#include <iostream>
#include <map>
#include <regex>
#include <set>
#include <unordered_map>

#include "flowutil.h"

using namespace flow;

namespace {
[[noreturn]] void die(const std::string& m)
{
  std::fprintf(stderr, "MERGE_ERROR: %s\n", m.c_str());
  std::exit(3);
}

std::string path_of(const std::string& dir, const char* f) { return join_path(dir, f); }

// offsets just after every newline
std::vector<size_t> line_ends(const std::string& data)
{
  std::vector<size_t> out;
  size_t pos = data.find('\n');
  while (pos != std::string::npos) { out.push_back(pos + 1); pos = data.find('\n', pos + 1); }
  return out;
}

std::pair<std::string, std::map<std::string, long long>> read_status(const std::string& path)
{
  auto lines = split(read_text(path), '\n');
  std::map<std::string, long long> vals;
  for (size_t i = 1; i < lines.size(); ++i) {
    auto k = lines[i].find('=');
    if (k != std::string::npos) vals[lines[i].substr(0, k)] = to_int(lines[i].substr(k + 1));
  }
  return {lines[0], vals};
}

std::map<std::string, std::string> meta_of(const std::string& header)
{
  std::map<std::string, std::string> m;
  std::string h = header;
  if (!h.empty() && h[0] == '#') h = h.substr(1);
  std::istringstream ss(h);
  std::string tok;
  while (ss >> tok) { auto k = tok.find('='); if (k != std::string::npos) m[tok.substr(0, k)] = tok.substr(k + 1); }
  return m;
}

int check_main(const std::string& G, int K, const std::string& tokf)
{
  std::string tok = read_text(tokf);
  std::string parts = join_path(G, "parts");
  std::vector<std::string> bad;
  std::vector<std::string> present;
  std::regex pre(R"(p\d+)");
  for (auto& d : list_dir(parts)) if (std::regex_match(d, pre)) present.push_back(d);
  std::vector<std::string> want;
  for (int k = 0; k < K; ++k) want.push_back("p" + std::to_string(k));
  std::sort(want.begin(), want.end());
  if (present != want) bad.push_back("partition dirs != expected (missing/extra/duplicated)");
  const char* need[] = {"pre_cts_ff_timing_graph.csv", "ff_admission_events.csv", "ff_admission.status", "ff_partition_index.csv",
                        "pre_cts_io_timing_edges.csv", "io_admission_events.csv", "io_admission.status", "io_partition_index.csv"};
  for (int k = 0; k < K; ++k) {
    std::string p = join_path(parts, "p" + std::to_string(k));
    if (!is_dir(p)) continue;
    std::string t = join_path(p, "RUN_TOKEN");
    if (!path_exists(t) || read_text(t) != tok + "partition=" + std::to_string(k) + "/" + std::to_string(K) + "\n")
      bad.push_back("p" + std::to_string(k) + ": token of a different run / partition");
    std::string rc = join_path(p, "RC");
    if (!path_exists(rc) || strip(read_text(rc)) != "0")
      bad.push_back("p" + std::to_string(k) + ": process failed or did not finish (RC=" + (path_exists(rc) ? strip(read_text(rc)) : "missing") + ")");
    std::string log = join_path(p, "console.log");
    if (!path_exists(log) || read_text(log).find("EXTRACT_DONE ") == std::string::npos) bad.push_back("p" + std::to_string(k) + ": script did not reach its end");
    for (const char* f : need) if (!path_exists(join_path(p, std::string("results/") + f))) bad.push_back("p" + std::to_string(k) + ": missing " + f);
    std::string idx = join_path(p, "results/ff_partition_index.csv");
    if (path_exists(idx)) {
      std::string h = read_lines(idx).at(0);
      if ((h + " ").find("partition=" + std::to_string(k) + "/" + std::to_string(K) + " ") == std::string::npos)
        bad.push_back("p" + std::to_string(k) + ": index header says " + h.substr(0, 60));
    }
  }
  if (!bad.empty()) {
    std::printf("PARTS_CHECK FAIL\n");
    for (auto& b : bad) std::printf("  %s\n", b.c_str());
    return 3;
  }
  std::printf("PARTS_CHECK OK K=%d\n", K);
  return 0;
}

struct Block { int k; size_t a, b, ea, eb, ia, ib; };

long long merge_ff(const std::vector<std::string>& parts, const std::string& out, std::map<std::string, long long>& sums)
{
  std::map<long long, Block> blocks;
  std::vector<std::pair<std::string, std::string>> datas;
  long long total_sources = -1;
  sums = {{"retained", 0}, {"unsupported", 0}, {"inactive_source_modes", 0}};
  std::set<std::string> headers, ev_headers;
  std::set<std::string> modes;  // "static" or "queue chunk=<S> items=<n>" per partition; must be one value
  int pi_owners = 0;
  for (size_t k = 0; k < parts.size(); ++k) {
    const std::string& rdir = parts[k];
    auto idx = split(read_text(path_of(rdir, "ff_partition_index.csv")), '\n');
    auto meta = meta_of(idx.at(0));
    std::string want = std::to_string(k) + "/" + std::to_string(parts.size());
    if (meta["partition"] != want) die("ff index of p" + std::to_string(k) + " says partition " + meta["partition"]);
    if (meta["queue"] == "1") {
      modes.insert("queue chunk=" + meta["chunk"] + " items=" + meta["items"]);
      if (meta["pi"] == "1") ++pi_owners;
    } else {
      modes.insert("static");
    }
    if (total_sources < 0) total_sources = to_int(meta["total_sources"]);
    else if (total_sources != to_int(meta["total_sources"])) die("partitions disagree on the launch universe size");
    std::vector<std::vector<std::string>> rows;
    for (size_t i = 2; i < idx.size(); ++i) {
      if (idx[i].empty()) continue;
      auto f = split(idx[i], ',');
      if (f.size() < 4) die("short ff index row");
      std::string name = f[3];
      for (size_t j = 4; j < f.size(); ++j) name += "," + f[j];
      rows.push_back({f[0], f[1], f[2], name});
    }
    if ((long long) rows.size() != to_int(meta["sources"])) die("ff index of p" + std::to_string(k) + ": row count differs from the header");
    auto st = read_status(path_of(rdir, "ff_admission.status"));
    for (auto& key : {"retained", "unsupported", "inactive_source_modes"}) {
      std::string name = std::string(key) == "retained" ? "retained_pathends" : key;
      if (st.second[name] != to_int(meta[key])) die("p" + std::to_string(k) + ": ff_admission.status " + name + " != index header");
      sums[key] += st.second[name];
    }
    if ((st.first == "BLOCKED") != (st.second["unsupported"] > 0)) die("p" + std::to_string(k) + ": ff status verdict inconsistent with its unsupported count");
    std::string csv = read_text(path_of(rdir, "pre_cts_ff_timing_graph.csv"));
    auto ends = line_ends(csv);
    long long n_edges = to_int(meta["edges"]);
    size_t n_src = rows.size();
    if (ends.size() != 1 + (size_t) n_edges + n_src || ends.back() != csv.size()) die("p" + std::to_string(k) + ": FF csv line count differs from the index");
    headers.insert(csv.substr(0, ends[0]));
    std::string ev = read_text(path_of(rdir, "ff_admission_events.csv"));
    size_t ev_head_end = ev.find('\n') + 1;
    ev_headers.insert(ev.substr(0, ev_head_end));
    long long prev_edge = 0;
    size_t prev_ev = ev_head_end;
    for (size_t i = 0; i < rows.size(); ++i) {
      long long order = to_int(rows[i][0]), edge_end = to_int(rows[i][1]);
      size_t event_end = (size_t) to_int(rows[i][2]);
      const std::string& name = rows[i][3];
      if (blocks.count(order)) die("launch order " + std::to_string(order) + " appears twice");
      if (edge_end < prev_edge || event_end < prev_ev) die("p" + std::to_string(k) + ": non-monotonic index at " + name);
      size_t a = ends[prev_edge], b = ends[edge_end];
      size_t ia = ends[n_edges + i], ib = ends[n_edges + i + 1];
      std::string bname = name + ",";
      if (b > a && csv.compare(a, bname.size(), bname) != 0) die("p" + std::to_string(k) + ": first FF row of launch " + name + " has another from_ff");
      if (b > a) {
        size_t last = b >= 2 ? csv.rfind('\n', b - 2) : std::string::npos;
        size_t start = (last != std::string::npos && last >= a) ? last + 1 : a;
        if (csv.compare(start, bname.size(), bname) != 0) die("p" + std::to_string(k) + ": last FF row of launch " + name + " has another from_ff");
      }
      std::string ident = name + "," + name + ",";
      if (csv.compare(ia, ident.size(), ident) != 0) die("p" + std::to_string(k) + ": identity row " + std::to_string(i) + " is not for " + name);
      blocks[order] = {(int) k, a, b, prev_ev, event_end, ia, ib};
      prev_edge = edge_end; prev_ev = event_end;
    }
    if (prev_edge != n_edges || prev_ev != ev.size()) die("p" + std::to_string(k) + ": index does not cover the whole FF csv / event file");
    datas.emplace_back(std::move(csv), std::move(ev));
  }
  if (headers.size() != 1 || ev_headers.size() != 1) die("FF headers differ between partitions");
  if (modes.size() != 1) die("partitions disagree on the launch distribution mode / chunk size");
  if (*modes.begin() != "static" && pi_owners != 1) die("queue mode: " + std::to_string(pi_owners) + " partitions ran the input-port side");
  if ((long long) blocks.size() != total_sources) die("launch coverage: " + std::to_string(blocks.size()) + " of " + std::to_string(total_sources) + " launches present");
  for (long long o = 0; o < total_sources; ++o) if (!blocks.count(o)) die("launch coverage: order " + std::to_string(o) + " missing");
  {
    std::ofstream f(join_path(out, "pre_cts_ff_timing_graph.csv"), std::ios::binary);
    f << *headers.begin();
    for (long long o = 0; o < total_sources; ++o) { const Block& b = blocks[o]; f.write(datas[b.k].first.data() + b.a, (std::streamsize) (b.b - b.a)); }
    for (long long o = 0; o < total_sources; ++o) { const Block& b = blocks[o]; f.write(datas[b.k].first.data() + b.ia, (std::streamsize) (b.ib - b.ia)); }
  }
  {
    std::ofstream f(join_path(out, "ff_admission_events.csv"), std::ios::binary);
    f << *ev_headers.begin();
    for (long long o = 0; o < total_sources; ++o) { const Block& b = blocks[o]; f.write(datas[b.k].second.data() + b.ea, (std::streamsize) (b.eb - b.ea)); }
  }
  {
    std::string s = std::string(sums["unsupported"] ? "BLOCKED" : "VALID") + "\nretained_pathends=" + std::to_string(sums["retained"]) +
                    "\nunsupported=" + std::to_string(sums["unsupported"]) + "\ninactive_source_modes=" + std::to_string(sums["inactive_source_modes"]) + "\n";
    write_text(join_path(out, "ff_admission.status"), s);
  }
  return total_sources;
}

struct Seg { std::string ev; std::vector<std::string> keys; };

std::vector<long long> merge_io(const std::vector<std::string>& parts, const std::string& out, long long total_sources, size_t& n_keys)
{
  bool have_pi = false;
  Seg pi;
  std::map<long long, Seg> seg;
  std::unordered_map<std::string, std::string> rows;
  std::unordered_map<std::string, int> key_owner;
  std::vector<long long> counters(8, 0);
  std::set<std::string> headers, ev_headers;
  int pi_owner = -1;
  std::set<bool> queue_modes;
  for (size_t k = 0; k < parts.size(); ++k) {
    const std::string& rdir = parts[k];
    auto idx = split(read_text(path_of(rdir, "io_partition_index.csv")), '\n');
    auto meta = meta_of(idx.at(0));
    if (meta["partition"] != std::to_string(k) + "/" + std::to_string(parts.size())) die("io index of p" + std::to_string(k) + " says " + idx[0]);
    // static header: exactly "#partition=k/K" (partition 0 owns the input-port side);
    // queue header: "#partition=k/K queue=1 pi=<0|1>"
    const bool queued = meta["queue"] == "1";
    if (!queued && idx[0] != "#partition=" + std::to_string(k) + "/" + std::to_string(parts.size())) die("io index of p" + std::to_string(k) + " says " + idx[0]);
    if (queued && meta["pi"] != "0" && meta["pi"] != "1") die("io index of p" + std::to_string(k) + " has no pi flag");
    queue_modes.insert(queued);
    const bool owns_pi = queued ? meta["pi"] == "1" : k == 0;
    if (owns_pi) {
      if (pi_owner >= 0) die("two partitions ran the input-port side");
      pi_owner = (int) k;
    }
    struct S { long long order; size_t audit_end, keys_end; std::string name; };
    std::vector<S> segs;
    std::vector<std::string> keys;
    long long p_ret = 0, p_uns = 0;
    for (size_t i = 1; i < idx.size(); ++i) {
      const std::string& ln = idx[i];
      if (starts_with(ln, "P,")) {
        auto v = split(ln, ',');
        for (size_t j = 1; j < v.size() && j - 1 < 8; ++j) counters[j - 1] += to_int(v[j]);
        p_ret = to_int(v.at(7)); p_uns = to_int(v.at(8));
      } else if (starts_with(ln, "S,")) {
        auto v = split(ln, ',');
        std::string name = v.size() > 4 ? v[4] : "";
        for (size_t j = 5; j < v.size(); ++j) name += "," + v[j];
        segs.push_back({to_int(v.at(1)), (size_t) to_int(v.at(2)), (size_t) to_int(v.at(3)), name});
      } else if (starts_with(ln, "K,")) keys.push_back(ln.substr(2));
    }
    auto st = read_status(path_of(rdir, "io_admission.status"));
    if (st.second["retained_pathends"] != p_ret || st.second["unsupported"] != p_uns) die("p" + std::to_string(k) + ": io_admission.status != index counters");
    if ((st.first == "BLOCKED") != (p_uns > 0)) die("p" + std::to_string(k) + ": io status verdict inconsistent with its unsupported count");
    std::string ev = read_text(path_of(rdir, "io_admission_events.csv"));
    size_t head_end = ev.find('\n') + 1;
    ev_headers.insert(ev.substr(0, head_end));
    if (segs.empty() || segs[0].order != -1) die("p" + std::to_string(k) + ": io index has no PI segment");
    size_t prev_ev = head_end, prev_key = 0;
    for (auto& s : segs) {
      if (s.audit_end < prev_ev || s.keys_end < prev_key) die("p" + std::to_string(k) + ": non-monotonic io index");
      Seg part;
      part.ev = ev.substr(prev_ev, s.audit_end - prev_ev);
      part.keys.assign(keys.begin() + prev_key, keys.begin() + s.keys_end);
      prev_ev = s.audit_end; prev_key = s.keys_end;
      if (s.order == -1) {
        if ((int) k == pi_owner) { pi = part; have_pi = true; }
        else if (!part.ev.empty() || !part.keys.empty()) die("p" + std::to_string(k) + " has PI-side output but did not run the input-port side");
      } else {
        if (seg.count(s.order)) die("io: launch order " + std::to_string(s.order) + " appears twice");
        seg[s.order] = part;
      }
    }
    if (prev_ev != ev.size() || prev_key != keys.size()) die("p" + std::to_string(k) + ": io index does not cover the event file / key list");
    for (auto& key : keys) {
      if (key_owner.count(key)) die("IO key " + key + " produced by two partitions");
      key_owner[key] = (int) k;
    }
    auto csv = split(read_text(path_of(rdir, "pre_cts_io_timing_edges.csv")), '\n');
    headers.insert(csv.at(0));
    size_t n_rows = 0;
    for (size_t i = 1; i < csv.size(); ++i) {
      const std::string& row = csv[i];
      if (row.empty()) continue;
      auto f = split(row, ',');
      if (f.size() != 6) die("p" + std::to_string(k) + ": IO row with " + std::to_string(f.size()) + " fields (comma in a name?)");
      std::string key = f[0] + "|" + f[1] + "|" + f[2];
      auto ko = key_owner.find(key);
      if (ko == key_owner.end() || ko->second != (int) k || rows.count(key)) die("p" + std::to_string(k) + ": IO row " + key + " not announced in its index");
      rows[key] = row;
      ++n_rows;
    }
    if (n_rows != keys.size()) die("p" + std::to_string(k) + ": IO rows and keys differ in number");
  }
  if (headers.size() != 1 || ev_headers.size() != 1) die("IO headers differ between partitions");
  if (queue_modes.size() != 1) die("IO indexes disagree on the launch distribution mode");
  if ((long long) seg.size() != total_sources) die("io launch coverage: " + std::to_string(seg.size()) + " of " + std::to_string(total_sources));
  for (long long o = 0; o < total_sources; ++o) if (!seg.count(o)) die("io launch coverage: order " + std::to_string(o) + " missing");
  if (!have_pi) die("no PI segment");
  std::vector<std::string> insert_order(pi.keys);
  for (long long o = 0; o < total_sources; ++o) insert_order.insert(insert_order.end(), seg[o].keys.begin(), seg[o].keys.end());
  for (auto& key : insert_order) if (key.find('\n') != std::string::npos) die("newline in IO key");
  // iteration order of the extractor's unordered_map (same key insertion sequence, same libstdc++)
  std::unordered_map<std::string, int> umap;
  for (auto& key : insert_order) umap[key];
  std::vector<std::string> iter_order;
  for (auto& kv : umap) iter_order.push_back(kv.first);
  {
    std::vector<std::string> a(iter_order), b(insert_order);
    std::sort(a.begin(), a.end()); std::sort(b.begin(), b.end());
    if (a != b) die("umap_order returned a different key set");
  }
  {
    std::ofstream f(join_path(out, "pre_cts_io_timing_edges.csv"), std::ios::binary);
    f << *headers.begin() << "\n";
    for (auto& key : iter_order) f << rows[key] << "\n";
  }
  {
    std::ofstream f(join_path(out, "io_admission_events.csv"), std::ios::binary);
    f << *ev_headers.begin() << pi.ev;
    for (long long o = 0; o < total_sources; ++o) f << seg[o].ev;
  }
  write_text(join_path(out, "io_admission.status"), std::string(counters[7] ? "BLOCKED" : "VALID") + "\nretained_pathends=" + std::to_string(counters[6]) +
                                                      "\nunsupported=" + std::to_string(counters[7]) + "\n");
  n_keys = insert_order.size();
  return counters;
}

int merge_main(const std::string& parts_dir, int k_total, const std::string& out)
{
  std::vector<std::string> parts;
  for (int k = 0; k < k_total; ++k) parts.push_back(join_path(parts_dir, "p" + std::to_string(k) + "/results"));
  mkdirs(out);
  auto t0 = std::chrono::steady_clock::now();
  if (k_total == 1) die("K=1 writes no partition index; use the single-process outputs directly");
  std::map<std::string, long long> sums;
  long long total = merge_ff(parts, out, sums);
  auto t1 = std::chrono::steady_clock::now();
  size_t n_keys = 0;
  auto counters = merge_io(parts, out, total, n_keys);
  auto t2 = std::chrono::steady_clock::now();
  char buf[1024];
  std::snprintf(buf, sizeof buf,
                "MERGE_OK partitions=%d launches=%lld ff_retained=%lld ff_unsupported=%lld ff_inactive_source_modes=%lld "
                "io_edges=%zu pi_setup=%lld pi_hold=%lld pi_removal=%lld pi_recovery=%lld po_setup=%lld po_hold=%lld "
                "io_retained=%lld io_unsupported=%lld merge_ff_s=%.1f merge_io_s=%.1f",
                k_total, total, sums["retained"], sums["unsupported"], sums["inactive_source_modes"], n_keys, counters[0], counters[1], counters[2],
                counters[3], counters[4], counters[5], counters[6], counters[7], std::chrono::duration<double>(t1 - t0).count(),
                std::chrono::duration<double>(t2 - t1).count());
  write_text(join_path(dirname_of(realpath_of(out)), "merge_summary.txt"), std::string(buf) + "\n");
  std::printf("%s\n", buf);
  return 0;
}
}  // namespace

int main(int argc, char** argv)
{
  try {
    std::string cmd = argc > 1 ? argv[1] : "";
    if (cmd == "check" && argc == 5) return check_main(argv[2], (int) to_int(argv[3]), argv[4]);
    if (cmd == "merge" && argc == 5) return merge_main(argv[2], (int) to_int(argv[3]), argv[4]);
    std::fprintf(stderr, "usage: cts_partitions check <G_dir> <K> <run_token_file> | merge <parts_dir> <K> <out_results_dir>\n");
    return 2;
  } catch (std::exception& e) {
    std::fprintf(stderr, "cts_partitions: %s\n", e.what());
    return 3;
  }
}
