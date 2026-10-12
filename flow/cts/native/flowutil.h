#pragma once
// Shared helpers of the native flow tools (flow/cts/native): file / CSV reading, number formatting, JSON reading and
// writing, sha256 and path helpers.  Same code as EarlyUtil.h of the OpenROAD patch.

#include <algorithm>
#include <climits>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace flow {

[[noreturn]] inline void fail(const std::string& m) { throw std::runtime_error(m); }

// ------------------------------------------------------------------------------------------------ files
inline std::vector<std::string> read_lines(const std::string& path)
{
  std::ifstream in(path);
  if (!in) fail("cannot read " + path);
  std::vector<std::string> out;
  std::string l;
  while (std::getline(in, l)) {
    if (!l.empty() && l.back() == '\r') l.pop_back();
    out.push_back(l);
  }
  return out;
}
inline std::string read_text(const std::string& path)
{
  std::ifstream in(path, std::ios::binary);
  if (!in) fail("cannot read " + path);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}
inline void write_text(const std::string& path, const std::string& s)
{
  std::ofstream out(path, std::ios::binary);
  if (!out) fail("cannot write " + path);
  out << s;
}
inline std::string join_path(const std::string& a, const std::string& b)
{
  if (a.empty()) return b;
  if (b.empty()) return a;
  return a.back() == '/' ? a + b : a + "/" + b;
}
inline std::string basename_of(const std::string& p)
{
  auto k = p.rfind('/');
  return k == std::string::npos ? p : p.substr(k + 1);
}
inline std::string dirname_of(const std::string& p)
{
  auto k = p.rfind('/');
  return k == std::string::npos ? "." : (k == 0 ? "/" : p.substr(0, k));
}
inline void mkdirs(const std::string& path)
{
  std::string cmd = "mkdir -p '" + path + "'";
  if (std::system(cmd.c_str()) != 0) fail("mkdir failed: " + path);
}
inline std::vector<std::string> split(const std::string& s, char sep)
{
  std::vector<std::string> out;
  size_t a = 0;
  while (true) {
    size_t b = s.find(sep, a);
    if (b == std::string::npos) { out.push_back(s.substr(a)); break; }
    out.push_back(s.substr(a, b - a));
    a = b + 1;
  }
  return out;
}
inline std::string strip(const std::string& s)
{
  size_t a = 0, b = s.size();
  while (a < b && std::isspace((unsigned char) s[a])) ++a;
  while (b > a && std::isspace((unsigned char) s[b - 1])) --b;
  return s.substr(a, b - a);
}
inline bool starts_with(const std::string& s, const char* p) { return s.compare(0, std::strlen(p), p) == 0; }
inline bool ends_with(const std::string& s, const char* p)
{
  size_t n = std::strlen(p);
  return s.size() >= n && s.compare(s.size() - n, n, p) == 0;
}
// inst of "inst/pin" (text before the last '/')
inline std::string inst_of(const std::string& pin)
{
  auto k = pin.rfind('/');
  return k == std::string::npos ? pin : pin.substr(0, k);
}

// ------------------------------------------------------------------------------------------------ numbers
inline double to_double(const std::string& s)
{
  const char* b = s.c_str();
  char* e = nullptr;
  double v = std::strtod(b, &e);
  while (e && *e && std::isspace((unsigned char) *e)) ++e;
  if (e == b || (e && *e)) fail("bad float '" + s + "'");
  return v;
}
inline long long to_int(const std::string& s)
{
  const char* b = s.c_str();
  char* e = nullptr;
  long long v = std::strtoll(b, &e, 10);
  while (e && *e && std::isspace((unsigned char) *e)) ++e;
  if (e == b || (e && *e)) fail("bad int '" + s + "'");
  return v;
}
// Shortest round-trip decimal representation: exponent form (e+XX / e-XX) if the decimal point position is <= -4 or
// > 16, otherwise fixed notation with at least one fractional digit; nan, inf, -inf, -0.0 spelled out.
inline std::string py_repr(double x)
{
  if (std::isnan(x)) return "nan";
  if (std::isinf(x)) return x > 0 ? "inf" : "-inf";
  if (x == 0) return std::signbit(x) ? "-0.0" : "0.0";
  char buf[64];
  auto r = std::to_chars(buf, buf + sizeof buf, x, std::chars_format::scientific);
  std::string s(buf, r.ptr);
  std::string sign;
  size_t i = 0;
  if (s[0] == '-') { sign = "-"; i = 1; }
  size_t e = s.find('e');
  std::string mant = s.substr(i, e - i);
  int exp = std::atoi(s.c_str() + e + 1);
  std::string digits;
  for (char c : mant) if (c != '.') digits += c;
  while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
  int nd = (int) digits.size();
  int decpt = exp + 1;
  std::string out;
  if (decpt <= -4 || decpt > 16) {
    out = digits.substr(0, 1);
    if (nd > 1) out += "." + digits.substr(1);
    char eb[16];
    std::snprintf(eb, sizeof eb, "e%c%02d", exp < 0 ? '-' : '+', std::abs(exp));
    out += eb;
  } else if (decpt <= 0) {
    out = "0." + std::string(-decpt, '0') + digits;
  } else if (decpt < nd) {
    out = digits.substr(0, decpt) + "." + digits.substr(decpt);
  } else {
    out = digits + std::string(decpt - nd, '0') + ".0";
  }
  return sign + out;
}
// Rounding to n decimal digits, correctly rounded from the binary value
inline double py_round(double x, int n)
{
  if (!std::isfinite(x)) return x;
  char buf[512];
  std::snprintf(buf, sizeof buf, "%.*f", n, x);
  return std::strtod(buf, nullptr);
}
// Integer floor division (quotient rounded toward negative infinity)
inline long long py_floordiv(long long a, long long b)
{
  long long q = a / b;
  if ((a % b != 0) && ((a < 0) != (b < 0))) --q;
  return q;
}


// ------------------------------------------------------------------------------------------------ CSV
// CSV / TSV table: header + rows (fields split on the separator; quoted fields honoured; CR stripped)
struct Table
{
  std::vector<std::string> header;
  std::vector<std::vector<std::string>> rows;
  std::unordered_map<std::string, int> index;
  int col(const std::string& name) const
  {
    auto it = index.find(name);
    if (it == index.end()) fail("missing column " + name);
    return it->second;
  }
  const std::string& at(size_t r, const std::string& name) const { return rows[r][col(name)]; }
};
inline std::vector<std::string> split_csv_line(const std::string& line, char sep)
{
  std::vector<std::string> out;
  std::string cur;
  bool q = false;
  for (size_t i = 0; i < line.size(); ++i) {
    char c = line[i];
    if (q) {
      if (c == '"') { if (i + 1 < line.size() && line[i + 1] == '"') { cur += '"'; ++i; } else q = false; }
      else cur += c;
    } else if (c == '"') q = true;
    else if (c == sep) { out.push_back(cur); cur.clear(); }
    else cur += c;
  }
  out.push_back(cur);
  return out;
}
inline Table read_table(const std::string& path, char sep = ',')
{
  Table t;
  auto lines = read_lines(path);
  if (lines.empty()) fail("empty table " + path);
  t.header = split_csv_line(lines[0], sep);
  for (size_t i = 0; i < t.header.size(); ++i) t.index.emplace(t.header[i], (int) i);
  for (size_t i = 1; i < lines.size(); ++i) {
    if (lines[i].empty()) continue;   // blank lines are skipped
    auto f = split_csv_line(lines[i], sep);
    while (f.size() < t.header.size()) f.push_back("");   // missing trailing fields are empty
    t.rows.push_back(std::move(f));
  }
  return t;
}
// CSV field, quoted only if it contains a comma, quote, CR or LF
inline std::string csv_field(const std::string& s)
{
  if (s.find_first_of(",\"\r\n") == std::string::npos) return s;
  std::string o = "\"";
  for (char c : s) { if (c == '"') o += '"'; o += c; }
  return o + "\"";
}
inline std::string csv_row(const std::vector<std::string>& f)
{
  std::string o;
  for (size_t i = 0; i < f.size(); ++i) { if (i) o += ','; o += csv_field(f[i]); }
  return o + "\r\n";
}

// ------------------------------------------------------------------------------------------------ JSON
// JSON value with insertion-ordered objects.  dump(n): one element per line, indented by n spaces per level;
// "," at line end and ": " after keys; empty containers as [] / {}; bytes outside 0x20..0x7e escaped as \u00XX;
// doubles as the shortest round-trip representation (NaN, Infinity, -Infinity).
struct J
{
  enum T { NUL, BOOL, INT, DBL, STR, ARR, OBJ } t = NUL;
  bool b = false;
  long long i = 0;
  double d = 0;
  std::string s;
  std::vector<J> a;
  std::vector<std::pair<std::string, J>> o;
  static J Null() { return J(); }
  static J B(bool v) { J j; j.t = BOOL; j.b = v; return j; }
  static J I(long long v) { J j; j.t = INT; j.i = v; return j; }
  static J D(double v) { J j; j.t = DBL; j.d = v; return j; }
  static J S(const std::string& v) { J j; j.t = STR; j.s = v; return j; }
  static J Arr() { J j; j.t = ARR; return j; }
  static J Obj() { J j; j.t = OBJ; return j; }
  J& push(const J& v) { a.push_back(v); return a.back(); }
  // dict assignment: overwrite in place or append
  J& set(const std::string& k, const J& v)
  {
    for (auto& kv : o) if (kv.first == k) { kv.second = v; return kv.second; }
    o.emplace_back(k, v);
    return o.back().second;
  }
  bool has(const std::string& k) const { for (auto& kv : o) if (kv.first == k) return true; return false; }
  const J& get(const std::string& k) const
  {
    for (auto& kv : o) if (kv.first == k) return kv.second;
    fail("json: missing key " + k);
  }
  const J* find(const std::string& k) const
  {
    for (auto& kv : o) if (kv.first == k) return &kv.second;
    return nullptr;
  }
  double num() const { return t == INT ? (double) i : (t == DBL ? d : (t == BOOL ? (b ? 1.0 : 0.0) : 0.0)); }
  static std::string esc(const std::string& s)
  {
    std::string o = "\"";
    for (unsigned char c : s) {
      switch (c) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        case '\b': o += "\\b"; break;
        case '\f': o += "\\f"; break;
        default:
          if (c < 0x20 || c >= 0x7f) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
          else o += (char) c;
      }
    }
    return o + "\"";
  }
  static std::string num_repr(double v)
  {
    if (std::isnan(v)) return "NaN";
    if (std::isinf(v)) return v > 0 ? "Infinity" : "-Infinity";
    return py_repr(v);
  }
  void dump_to(std::string& out, int indent, int level) const
  {
    switch (t) {
      case NUL: out += "null"; break;
      case BOOL: out += b ? "true" : "false"; break;
      case INT: out += std::to_string(i); break;
      case DBL: out += num_repr(d); break;
      case STR: out += esc(s); break;
      case ARR:
        if (a.empty()) { out += "[]"; break; }
        out += "[";
        for (size_t k = 0; k < a.size(); ++k) {
          if (k) out += ",";
          out += "\n" + std::string((size_t) indent * (level + 1), ' ');
          a[k].dump_to(out, indent, level + 1);
        }
        out += "\n" + std::string((size_t) indent * level, ' ') + "]";
        break;
      case OBJ:
        if (o.empty()) { out += "{}"; break; }
        out += "{";
        for (size_t k = 0; k < o.size(); ++k) {
          if (k) out += ",";
          out += "\n" + std::string((size_t) indent * (level + 1), ' ') + esc(o[k].first) + ": ";
          o[k].second.dump_to(out, indent, level + 1);
        }
        out += "\n" + std::string((size_t) indent * level, ' ') + "}";
        break;
    }
  }
  std::string dump(int indent = 1) const
  {
    std::string out;
    dump_to(out, indent, 0);
    return out;
  }
};

// minimal JSON reader (objects keep key order)
struct JsonParser
{
  const std::string& s;
  size_t p = 0;
  explicit JsonParser(const std::string& text) : s(text) {}
  void ws() { while (p < s.size() && std::isspace((unsigned char) s[p])) ++p; }
  J parse()
  {
    ws();
    if (p >= s.size()) fail("json: unexpected end");
    char c = s[p];
    if (c == '{') {
      J j = J::Obj(); ++p; ws();
      if (s[p] == '}') { ++p; return j; }
      while (true) {
        ws(); J k = parse_string(); ws();
        if (s[p] != ':') fail("json: expected ':'"); ++p;
        J v = parse(); j.o.emplace_back(k.s, v); ws();
        if (s[p] == ',') { ++p; continue; }
        if (s[p] == '}') { ++p; return j; }
        fail("json: expected ',' or '}'");
      }
    }
    if (c == '[') {
      J j = J::Arr(); ++p; ws();
      if (s[p] == ']') { ++p; return j; }
      while (true) {
        j.a.push_back(parse()); ws();
        if (s[p] == ',') { ++p; continue; }
        if (s[p] == ']') { ++p; return j; }
        fail("json: expected ',' or ']'");
      }
    }
    if (c == '"') return parse_string();
    if (s.compare(p, 4, "true") == 0) { p += 4; return J::B(true); }
    if (s.compare(p, 5, "false") == 0) { p += 5; return J::B(false); }
    if (s.compare(p, 4, "null") == 0) { p += 4; return J::Null(); }
    if (s.compare(p, 3, "NaN") == 0) { p += 3; return J::D(std::nan("")); }
    if (s.compare(p, 8, "Infinity") == 0) { p += 8; return J::D(INFINITY); }
    if (s.compare(p, 9, "-Infinity") == 0) { p += 9; return J::D(-INFINITY); }
    size_t b = p;
    bool flt = false;
    while (p < s.size() && (std::isdigit((unsigned char) s[p]) || s[p] == '-' || s[p] == '+' || s[p] == '.' || s[p] == 'e' || s[p] == 'E')) {
      if (s[p] == '.' || s[p] == 'e' || s[p] == 'E') flt = true;
      ++p;
    }
    if (b == p) fail("json: bad token");
    std::string tok = s.substr(b, p - b);
    return flt ? J::D(to_double(tok)) : J::I(to_int(tok));
  }
  J parse_string()
  {
    if (s[p] != '"') fail("json: expected string");
    ++p;
    std::string o;
    while (p < s.size() && s[p] != '"') {
      if (s[p] == '\\') {
        ++p;
        char e = s[p++];
        switch (e) {
          case 'n': o += '\n'; break; case 't': o += '\t'; break; case 'r': o += '\r'; break;
          case 'b': o += '\b'; break; case 'f': o += '\f'; break;
          case 'u': { unsigned v = std::stoul(s.substr(p, 4), nullptr, 16); p += 4;
            if (v < 0x80) o += (char) v; else if (v < 0x800) { o += (char) (0xC0 | (v >> 6)); o += (char) (0x80 | (v & 0x3F)); }
            else { o += (char) (0xE0 | (v >> 12)); o += (char) (0x80 | ((v >> 6) & 0x3F)); o += (char) (0x80 | (v & 0x3F)); } break; }
          default: o += e;
        }
      } else o += s[p++];
    }
    ++p;
    return J::S(o);
  }
};
inline J json_load(const std::string& path)
{
  std::string text = read_text(path);
  JsonParser pr(text);
  return pr.parse();
}


// ------------------------------------------------------------------------------------------------ paths / hashes
inline std::string realpath_of(const std::string& p)
{
  char buf[PATH_MAX];
  if (!::realpath(p.c_str(), buf)) fail("cannot resolve " + p);
  return buf;
}
inline bool is_dir(const std::string& p) { struct stat st; return ::stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode); }
inline bool is_link(const std::string& p) { struct stat st; return ::lstat(p.c_str(), &st) == 0 && S_ISLNK(st.st_mode); }
inline bool path_exists(const std::string& p) { struct stat st; return ::stat(p.c_str(), &st) == 0; }
inline std::vector<std::string> list_dir(const std::string& d)
{
  std::vector<std::string> out;
  DIR* dir = ::opendir(d.c_str());
  if (!dir) fail("cannot list " + d);
  while (dirent* e = ::readdir(dir)) { std::string n = e->d_name; if (n != "." && n != "..") out.push_back(n); }
  ::closedir(dir);
  std::sort(out.begin(), out.end());
  return out;
}
// every file below root (recursive), full paths
inline void walk_files(const std::string& root, std::vector<std::string>& out)
{
  for (auto& n : list_dir(root)) {
    std::string p = join_path(root, n);
    if (is_dir(p)) walk_files(p, out); else out.push_back(p);
  }
}
inline std::string sha256_file(const std::string& path)
{
  std::string cmd = "sha256sum -- '" + path + "'";
  FILE* f = ::popen(cmd.c_str(), "r");
  if (!f) fail("sha256sum failed for " + path);
  char buf[256] = {0};
  if (!std::fgets(buf, sizeof buf, f)) { ::pclose(f); fail("sha256sum produced no output for " + path); }
  ::pclose(f);
  std::string s(buf);
  return s.substr(0, 64);
}
// list of strings in bracket notation: ['a', 'b']
inline std::string py_list_repr(const std::vector<std::string>& v)
{
  std::string o = "[";
  for (size_t i = 0; i < v.size(); ++i) { if (i) o += ", "; o += "'" + v[i] + "'"; }
  return o + "]";
}

}  // namespace flow
